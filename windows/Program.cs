using System;
using System.Threading;
using System.Windows.Forms;

namespace Liftstream
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            // Uma janela só: abrir de novo não deve disputar as portas com a que já está aberta.
            bool primeira;
            using (new Mutex(true, "Liftstream.Janela", out primeira))
            {
                if (!primeira) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new Janela());
            }
        }
    }
}
