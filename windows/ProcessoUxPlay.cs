using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Liftstream
{
    sealed class ProcessoUxPlay
    {
        public event Action IphoneSaiu;
        public event Action Terminou;

        Process processo;

        // "ctrl+c" quando o UxPlay saiu com o Ctrl+C (o MP4 fecha direito) e "kill" quando foi preciso encerrá-lo à força.
        public string ComoParou { get; private set; }

        public bool Rodando
        {
            get
            {
                try { return processo != null && !processo.HasExited; }
                catch { return false; }
            }
        }

        public static string Executavel { get { return Path.Combine(Config.Pasta, "uxplay.exe"); } }

        // Devolve null quando o UxPlay partiu, ou a mensagem do que deu errado.
        public string Iniciar(bool gravando)
        {
            if (!File.Exists(Executavel)) return "Não encontrei o uxplay.exe ao lado do Liftstream.exe.";
            EncerrarOrfaos();
            Directory.CreateDirectory(Config.Dados);

            var args = new StringBuilder();
            args.Append("-n ").Append(Config.NomeAirPlay)
                .Append(" -nh -p ").Append(Config.PortaAirPlay)
                .Append(" -m ").Append(Config.MacFixo)
                .Append(" -fps 60 -vsync no -d 1 ")
                .Append("-vs \"queue leaky=downstream max-size-buffers=2 ! jpegenc quality=85 ! multipartmux boundary=espelhopip ! tcpclientsink host=127.0.0.1 port=")
                .Append(Config.PortaQuadros).Append('"');

            string trabalho = Config.Pasta;
            if (gravando)
            {
                // O UxPlay cola este nome, sem aspas, no texto do pipeline do GStreamer: com espaço (no nome ou na pasta,
                // e "C:\Users\Maria Silva" é comum) o pipeline é recusado e nada é gravado. Vai só um nome sem espaço,
                // e a pasta vem do diretório de trabalho.
                Directory.CreateDirectory(Config.Gravacoes);
                trabalho = Config.Gravacoes;
                args.Append(" -mp4 iPhone_").Append(DateTime.Now.ToString("yyyy-MM-dd_HH.mm.ss", CultureInfo.InvariantCulture));
            }

            var info = new ProcessStartInfo
            {
                FileName = Executavel,
                Arguments = args.ToString(),
                WorkingDirectory = trabalho,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            // O GStreamer vem dentro da pasta do app; as DLLs ao lado do uxplay.exe são achadas pelo Windows.
            var plugins = Path.Combine(Config.Pasta, "plugins");
            if (Directory.Exists(plugins))
            {
                info.EnvironmentVariables["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins;
                info.EnvironmentVariables.Remove("GST_PLUGIN_PATH_1_0");
                info.EnvironmentVariables.Remove("GST_PLUGIN_PATH");
                info.EnvironmentVariables["GST_PLUGIN_SCANNER"] = Path.Combine(Config.Pasta, "gst-plugin-scanner.exe");
                info.EnvironmentVariables["GST_REGISTRY_1_0"] = Path.Combine(Config.Dados, "registro-gstreamer.bin");
                info.EnvironmentVariables["PATH"] = Config.Pasta + ";" + Environment.GetEnvironmentVariable("PATH");
            }

            StreamWriter registro;
            try
            {
                registro = new StreamWriter(new FileStream(Config.Registro, FileMode.Create, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
                registro.AutoFlush = true;
            }
            catch { registro = null; }

            var p = new Process { StartInfo = info, EnableRaisingEvents = true };
            DataReceivedEventHandler ao = (s, e) =>
            {
                if (e.Data == null) return;
                if (registro != null)
                {
                    lock (registro) { try { registro.WriteLine(e.Data); } catch { } }
                }
                // A conexão TCP dos quadros fica aberta o tempo todo; quem avisa que o iPhone saiu é o registro do UxPlay.
                if (e.Data.Contains("Open connections: 0") && ReferenceEquals(p, processo)) IphoneSaiu?.Invoke();
            };
            p.OutputDataReceived += ao;
            p.ErrorDataReceived += ao;
            p.Exited += (s, e) =>
            {
                if (!ReferenceEquals(p, processo)) return;
                Terminou?.Invoke();
            };
            try
            {
                processo = p;
                p.Start();
            }
            catch (Exception e)
            {
                processo = null;
                return e.Message;
            }
            Trabalho.Adicionar(p);
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            return null;
        }

        // Com gravação ligada, tenta um Ctrl+C para o UxPlay fechar o MP4 direito; sem resposta em 3 segundos, encerra.
        public void Parar(bool esperar)
        {
            var p = processo;
            if (p == null) return;
            ThreadStart parar = () =>
            {
                try
                {
                    if (p.HasExited) return;
                    if (Trabalho.EnviarCtrlC(p.Id) && p.WaitForExit(3000))
                    {
                        ComoParou = "ctrl+c";
                        return;
                    }
                    ComoParou = "kill";
                    if (!p.HasExited) p.Kill();
                }
                catch { }
            };
            if (esperar) parar();
            else new Thread(parar) { IsBackground = true }.Start();
        }

        public void Matar()
        {
            var p = processo;
            try { if (p != null && !p.HasExited) p.Kill(); } catch { }
        }

        // Um UxPlay que sobrou de uma execução interrompida seguraria as portas.
        static void EncerrarOrfaos()
        {
            foreach (var p in Process.GetProcessesByName("uxplay"))
            {
                try
                {
                    if (string.Equals(p.MainModule.FileName, Executavel, StringComparison.OrdinalIgnoreCase))
                    {
                        p.Kill();
                        p.WaitForExit(2000);
                    }
                }
                catch { }
                finally { p.Dispose(); }
            }
        }
    }

    // Um "job" do Windows que mata o UxPlay se o Liftstream fechar de qualquer jeito, inclusive travado.
    static class Trabalho
    {
        static IntPtr job;

        public static void Adicionar(Process p)
        {
            try
            {
                if (job == IntPtr.Zero)
                {
                    job = CreateJobObject(IntPtr.Zero, null);
                    var limite = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                    limite.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                    int tamanho = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                    IntPtr memoria = Marshal.AllocHGlobal(tamanho);
                    try
                    {
                        Marshal.StructureToPtr(limite, memoria, false);
                        SetInformationJobObject(job, 9, memoria, (uint)tamanho); // JobObjectExtendedLimitInformation
                    }
                    finally { Marshal.FreeHGlobal(memoria); }
                }
                AssignProcessToJobObject(job, p.Handle);
            }
            catch { }
        }

        // Anexa-se ao console escondido do UxPlay, manda Ctrl+C só para ele e solta o console.
        public static bool EnviarCtrlC(int pid)
        {
            try
            {
                if (!AttachConsole((uint)pid)) return false;
                SetConsoleCtrlHandler(IntPtr.Zero, true); // o Liftstream ignora o Ctrl+C enquanto está anexado
                bool ok = GenerateConsoleCtrlEvent(0, 0);
                Thread.Sleep(200);
                FreeConsole();
                SetConsoleCtrlHandler(IntPtr.Zero, false);
                return ok;
            }
            catch { return false; }
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateJobObject(IntPtr atributos, string nome);

        [DllImport("kernel32.dll")]
        static extern bool SetInformationJobObject(IntPtr job, int classe, IntPtr info, uint tamanho);

        [DllImport("kernel32.dll")]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr processo);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AttachConsole(uint pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool FreeConsole();

        [DllImport("kernel32.dll")]
        static extern bool SetConsoleCtrlHandler(IntPtr rotina, bool adicionar);

        [DllImport("kernel32.dll")]
        static extern bool GenerateConsoleCtrlEvent(uint evento, uint grupo);
    }
}
