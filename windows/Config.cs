using System;
using System.IO;
using System.Reflection;

namespace Liftstream
{
    static class Config
    {
        public const string NomeAirPlay = "Liftstream";
        public const int PortaQuadros = 7171;
        public const string PortaAirPlay = "7300";
        public const string MacFixo = "02:45:50:49:50:01";
        public const string Repositorio = "edsonlifts/liftstream";
        public const string ArquivoDoRelease = "Liftstream-Windows.zip";

        public static readonly string Pasta = AppDomain.CurrentDomain.BaseDirectory;
        public static readonly string Dados = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Liftstream");
        public static readonly string Registro = Path.Combine(Dados, "Liftstream.log");
        public static readonly string Gravacoes = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "Liftstream");

        // 1.0.1.0 vira "1.0.1", o mesmo formato da tag do release.
        public static string Versao
        {
            get
            {
                var v = Assembly.GetExecutingAssembly().GetName().Version;
                return v.Major + "." + v.Minor + "." + v.Build;
            }
        }
    }
}
