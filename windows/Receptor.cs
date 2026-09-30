using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace Liftstream
{
    // O UxPlay recebe o AirPlay e manda cada quadro como JPEG (multipart) por TCP local para cá.
    sealed class ReceptorDeQuadros
    {
        public event Action<Bitmap> QuadroPronto;
        public event Action<bool> ConexaoMudou;

        static readonly byte[] FimDoCabecalho = { 13, 10, 13, 10 };

        readonly object trava = new object();
        TcpListener ouvinte;
        TcpClient cliente;
        byte[] buffer = new byte[1 << 20];
        int usados;
        byte[] pendente;
        bool decodificando;

        // O UxPlay conecta assim que parte, então ele só pode ser iniciado depois que a porta estiver aberta.
        // Devolve null quando deu certo, ou o último erro depois de 10 tentativas.
        public Exception Iniciar()
        {
            Exception ultimo = null;
            for (int tentativa = 1; tentativa <= 10; tentativa++)
            {
                try
                {
                    ouvinte = new TcpListener(IPAddress.Loopback, Config.PortaQuadros);
                    ouvinte.Start();
                    new Thread(Aceitar) { IsBackground = true, Name = "quadros" }.Start();
                    return null;
                }
                catch (Exception e)
                {
                    ultimo = e;
                    Thread.Sleep(1000);
                }
            }
            return ultimo;
        }

        public void Fechar()
        {
            try { ouvinte?.Stop(); } catch { }
            lock (trava)
            {
                try { cliente?.Close(); } catch { }
                cliente = null;
            }
        }

        void Aceitar()
        {
            while (true)
            {
                TcpClient novo;
                try { novo = ouvinte.AcceptTcpClient(); }
                catch { return; }
                novo.NoDelay = true;
                lock (trava)
                {
                    try { cliente?.Close(); } catch { }
                    cliente = novo;
                    usados = 0;
                    pendente = null;
                }
                ConexaoMudou?.Invoke(true);
                new Thread(() => Ler(novo)) { IsBackground = true, Name = "leitura" }.Start();
            }
        }

        void Ler(TcpClient c)
        {
            var bloco = new byte[1 << 16];
            try
            {
                var fluxo = c.GetStream();
                while (true)
                {
                    int n = fluxo.Read(bloco, 0, bloco.Length);
                    if (n <= 0) break;
                    lock (trava)
                    {
                        if (!ReferenceEquals(cliente, c)) return;
                        Anexar(bloco, n);
                        ExtrairQuadros();
                    }
                }
            }
            catch { }
            bool eraOAtual;
            lock (trava)
            {
                eraOAtual = ReferenceEquals(cliente, c);
                if (eraOAtual) cliente = null;
            }
            try { c.Close(); } catch { }
            if (eraOAtual) ConexaoMudou?.Invoke(false);
        }

        void Anexar(byte[] dados, int n)
        {
            if (usados + n > buffer.Length)
            {
                if (usados + n > 32 << 20) usados = 0;
                else Array.Resize(ref buffer, Math.Max(buffer.Length * 2, usados + n));
            }
            Buffer.BlockCopy(dados, 0, buffer, usados, n);
            usados += n;
        }

        // Cada quadro vem como "cabeçalho (com Content-Length) + linha em branco + JPEG".
        void ExtrairQuadros()
        {
            byte[] ultimo = null;
            int inicio = 0;
            while (true)
            {
                int fim = Procurar(buffer, inicio, usados, FimDoCabecalho);
                if (fim < 0) break;
                int tamanho = TamanhoDoConteudo(Encoding.ASCII.GetString(buffer, inicio, fim - inicio));
                int corpo = fim + FimDoCabecalho.Length;
                if (tamanho < 0)
                {
                    inicio = corpo;
                    continue;
                }
                if (usados - corpo < tamanho) break;
                var jpeg = new byte[tamanho];
                Buffer.BlockCopy(buffer, corpo, jpeg, 0, tamanho);
                ultimo = jpeg;
                inicio = corpo + tamanho;
            }
            if (inicio > 0)
            {
                Buffer.BlockCopy(buffer, inicio, buffer, 0, usados - inicio);
                usados -= inicio;
            }
            if (ultimo != null) Enfileirar(ultimo);
        }

        static int Procurar(byte[] dados, int inicio, int fim, byte[] padrao)
        {
            for (int i = inicio; i <= fim - padrao.Length; i++)
            {
                int j = 0;
                while (j < padrao.Length && dados[i + j] == padrao[j]) j++;
                if (j == padrao.Length) return i;
            }
            return -1;
        }

        static int TamanhoDoConteudo(string cabecalho)
        {
            foreach (var linha in cabecalho.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                int dois = linha.IndexOf(':');
                if (dois > 0 && linha.Substring(0, dois).Trim().Equals("content-length", StringComparison.OrdinalIgnoreCase)
                    && int.TryParse(linha.Substring(dois + 1).Trim(), out int n))
                    return n;
            }
            return -1;
        }

        // Se a decodificação atrasar, pula quadros e mostra sempre o mais recente.
        // Chamado com a trava tomada.
        void Enfileirar(byte[] jpeg)
        {
            pendente = jpeg;
            if (decodificando) return;
            decodificando = true;
            ThreadPool.QueueUserWorkItem(_ => Proximo());
        }

        void Proximo()
        {
            while (true)
            {
                byte[] jpeg;
                lock (trava)
                {
                    jpeg = pendente;
                    pendente = null;
                    if (jpeg == null)
                    {
                        decodificando = false;
                        return;
                    }
                }
                try
                {
                    var quadro = Decodificar(jpeg);
                    var aviso = QuadroPronto;
                    if (aviso != null) aviso(quadro); else quadro.Dispose();
                }
                catch { }
            }
        }

        // Formato pré-multiplicado é o que o GDI+ desenha mais rápido. A cópia também solta o fluxo do JPEG.
        static Bitmap Decodificar(byte[] jpeg)
        {
            using (var memoria = new MemoryStream(jpeg))
            using (var origem = new Bitmap(memoria))
            {
                var pronto = new Bitmap(origem.Width, origem.Height, PixelFormat.Format32bppPArgb);
                using (var g = Graphics.FromImage(pronto))
                    g.DrawImage(origem, new Rectangle(0, 0, origem.Width, origem.Height));
                return pronto;
            }
        }
    }
}
