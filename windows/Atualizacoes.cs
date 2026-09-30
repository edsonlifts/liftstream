using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace Liftstream
{
    sealed class VersaoNova
    {
        public string Numero;
        public string Notas;
        public Uri Endereco;
    }

    // Avisa quando há versão nova no GitHub Releases. Só consulta e abre a página de download; não instala nada.
    static class Atualizacoes
    {
        // 1.10 é maior que 1.9, e 1.0 é igual a 1.0.0.
        public static bool EhMaior(string nova, string atual)
        {
            var a = Partes(nova);
            var b = Partes(atual);
            for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
            {
                int x = i < a.Length ? a[i] : 0;
                int y = i < b.Length ? b[i] : 0;
                if (x != y) return x > y;
            }
            return false;
        }

        static int[] Partes(string versao)
        {
            var texto = versao.Trim().TrimStart('v', 'V').Split('.');
            var numeros = new int[texto.Length];
            for (int i = 0; i < texto.Length; i++) int.TryParse(texto[i], out numeros[i]);
            return numeros;
        }

        // fim(true, null) quer dizer "está em dia"; fim(false, null) é rede fora do ar ou resposta estranha.
        public static void Consultar(Action<bool, VersaoNova> fim)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                    // LIFTSTREAM_ATUALIZACAO_URL existe para testar com uma resposta local (também aceita file:///).
                    var url = Environment.GetEnvironmentVariable("LIFTSTREAM_ATUALIZACAO_URL")
                        ?? "https://api.github.com/repos/" + Config.Repositorio + "/releases/latest";
                    var pedido = WebRequest.Create(url);
                    pedido.Timeout = 10000;
                    var http = pedido as HttpWebRequest;
                    if (http != null)
                    {
                        http.UserAgent = "Liftstream/" + Config.Versao;
                        http.Accept = "application/vnd.github+json";
                    }
                    string texto;
                    using (var resposta = pedido.GetResponse())
                    {
                        var h = resposta as HttpWebResponse;
                        if (h != null && h.StatusCode != HttpStatusCode.OK)
                        {
                            fim(false, null);
                            return;
                        }
                        using (var leitor = new StreamReader(resposta.GetResponseStream(), Encoding.UTF8))
                            texto = leitor.ReadToEnd();
                    }

                    var json = new JavaScriptSerializer().DeserializeObject(texto) as Dictionary<string, object>;
                    object valor;
                    if (json == null || !json.TryGetValue("tag_name", out valor) || !(valor is string))
                    {
                        fim(false, null);
                        return;
                    }
                    var tag = (string)valor;
                    if (!EhMaior(tag, Config.Versao))
                    {
                        fim(true, null);
                        return;
                    }

                    // O zip direto é um clique só; sem ele (o Windows demora uns minutos para subir), a página do release.
                    string destino = null;
                    if (json.TryGetValue("assets", out valor) && valor is object[])
                    {
                        foreach (var item in (object[])valor)
                        {
                            var asset = item as Dictionary<string, object>;
                            if (asset != null && (asset["name"] as string) == Config.ArquivoDoRelease)
                                destino = asset["browser_download_url"] as string;
                        }
                    }
                    if (destino == null && json.TryGetValue("html_url", out valor)) destino = valor as string;
                    Uri uri;
                    if (destino == null || !Uri.TryCreate(destino, UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps)
                    {
                        fim(false, null);
                        return;
                    }
                    var notas = json.TryGetValue("body", out valor) ? (valor as string ?? "") : "";
                    fim(true, new VersaoNova { Numero = tag.TrimStart('v', 'V'), Notas = notas.Trim(), Endereco = uri });
                }
                catch
                {
                    fim(false, null);
                }
            });
        }
    }
}
