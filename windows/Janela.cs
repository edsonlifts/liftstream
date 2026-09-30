using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace Liftstream
{
    // A janela flutuante: mostra o último quadro do iPhone, sempre na frente, sem bordas.
    sealed class Janela : Form
    {
        // Cores da Lifts (skill lifts-design, fundação §2.1).
        static readonly Color Deep = Color.FromArgb(0x06, 0x0F, 0x1A);
        static readonly Color Lime = Color.FromArgb(0xCC, 0xCB, 0x3F);
        // Branco a 85% sobre o deep (acima do piso de .50 da Lifts), já misturado porque o TextRenderer ignora transparência.
        static readonly Color Texto = Color.FromArgb(218, 219, 221);

        const int WM_NCHITTEST = 0x84, WM_NCLBUTTONDBLCLK = 0xA3, WM_NCRBUTTONUP = 0xA5, WM_CONTEXTMENU = 0x7B, WM_SIZING = 0x214;
        const int HTCAPTION = 2, HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13, HTTOPRIGHT = 14;
        const int HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;
        const int WS_EX_TRANSPARENT = 0x20;

        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }

        readonly ReceptorDeQuadros receptor = new ReceptorDeQuadros();
        readonly ProcessoUxPlay uxplay = new ProcessoUxPlay();
        readonly string pastaCaptura = Environment.GetEnvironmentVariable("LIFTSTREAM_CAPTURA");
        readonly object trocaQuadro = new object();

        Bitmap quadro, quadroPendente;
        bool entregaAgendada;
        Size tamanhoDoQuadro;
        string aviso;
        Image logo;
        int ladoMaior;
        bool gravando, encerrando, reiniciandoDeProposito, cliquesPassam, atualizacaoAberta, primeiroQuadroVisto;
        int reinicios;

        ContextMenuStrip menu;
        ToolStripMenuItem itemFrente, itemCliques, itemGravar;
        NotifyIcon bandeja;

        float Escala { get { return DeviceDpi / 96f; } }
        static string TextoEspera
        {
            get { return "No iPhone, abra a Central de Controle,\ntoque em Espelhar Tela e escolha\n“" + Config.NomeAirPlay + "”."; }
        }

        public Janela()
        {
            Text = Config.NomeAirPlay;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            MaximizeBox = false;
            TopMost = true;
            BackColor = Deep;
            AutoScaleMode = AutoScaleMode.None;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            // Com a janela "quase" opaca ela vira uma janela em camadas, o que a opacidade e o "deixar os cliques passarem" exigem.
            Opacity = 0.999;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            using (var fluxo = Assembly.GetExecutingAssembly().GetManifestResourceStream("logo-horizontal.png"))
            using (var origem = Image.FromStream(fluxo))
                logo = new Bitmap(origem);

            ladoMaior = (int)Math.Round(640 * Escala);
            ClientSize = new Size((int)Math.Round(295 * Escala), ladoMaior);
            MinimumSize = new Size((int)(120 * Escala), (int)(120 * Escala));
            var area = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(area.Right - Width - (int)(24 * Escala), area.Top + (int)(24 * Escala));

            MontarMenu();

            receptor.QuadroPronto += ReceberQuadro;
            receptor.ConexaoMudou += conectado => { if (!conectado) UI(IphoneSaiu); };
            uxplay.IphoneSaiu += () => UI(IphoneSaiu);
            uxplay.Terminou += () => UI(UxPlayParou);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                if (cliquesPassam) cp.ExStyle |= WS_EX_TRANSPARENT;
                return cp;
            }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            try { Directory.CreateDirectory(Config.Dados); } catch { }
            MostrarAviso(TextoEspera);
            if (pastaCaptura != null) IniciarCaptura();
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var erro = receptor.Iniciar();
                UI(() =>
                {
                    if (erro != null) MostrarAviso("Não consegui abrir a porta " + Config.PortaQuadros + ".\n" + erro.Message);
                    else IniciarUxPlay();
                });
            });
            Depois(3000, () => VerificarAtualizacao(false));
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            encerrando = true;
            if (bandeja != null)
            {
                bandeja.Visible = false;
                bandeja.Dispose();
            }
            if (gravando) uxplay.Parar(true); else uxplay.Matar();
            receptor.Fechar();
            base.OnFormClosing(e);
        }

        // ---- Thread da interface ----

        // Devolve false se a janela já não existe (ou ainda não).
        bool UI(Action acao)
        {
            if (IsDisposed || !IsHandleCreated) return false;
            try { BeginInvoke(acao); return true; }
            catch (InvalidOperationException) { return false; }
        }

        void Depois(int milissegundos, Action acao)
        {
            var t = new System.Windows.Forms.Timer { Interval = milissegundos };
            t.Tick += (s, e) =>
            {
                t.Stop();
                t.Dispose();
                acao();
            };
            t.Start();
        }

        // ---- Quadros ----

        // Se a interface atrasar, só o quadro mais recente importa.
        void ReceberQuadro(Bitmap b)
        {
            lock (trocaQuadro)
            {
                if (quadroPendente != null) quadroPendente.Dispose();
                quadroPendente = b;
                if (entregaAgendada) return;
                entregaAgendada = true;
            }
            if (!UI(EntregarQuadro))
            {
                lock (trocaQuadro)
                {
                    entregaAgendada = false;
                    if (quadroPendente != null) quadroPendente.Dispose();
                    quadroPendente = null;
                }
            }
        }

        void EntregarQuadro()
        {
            Bitmap b;
            lock (trocaQuadro)
            {
                b = quadroPendente;
                quadroPendente = null;
                entregaAgendada = false;
            }
            if (b == null) return;
            if (encerrando) { b.Dispose(); return; }
            Mostrar(b);
        }

        void Mostrar(Bitmap novo)
        {
            reinicios = 0;
            var antigo = quadro;
            quadro = novo;
            aviso = null;
            if (novo.Size != tamanhoDoQuadro)
            {
                tamanhoDoQuadro = novo.Size;
                AjustarJanela();
            }
            Invalidate();
            if (antigo != null) antigo.Dispose();
            if (pastaCaptura != null && !primeiroQuadroVisto)
            {
                primeiroQuadroVisto = true;
                Depois(3000, () =>
                {
                    Capturar("video.png");
                    EscreverCaptura("ok.txt", "quadro " + tamanhoDoQuadro.Width + "x" + tamanhoDoQuadro.Height);
                    Application.Exit();
                });
            }
        }

        void MostrarAviso(string texto)
        {
            if (quadro != null)
            {
                quadro.Dispose();
                quadro = null;
            }
            aviso = texto;
            Invalidate();
        }

        void IphoneSaiu()
        {
            tamanhoDoQuadro = Size.Empty;
            MostrarAviso(TextoEspera);
        }

        // Mantém o canto superior direito no lugar ao girar o iPhone ou trocar o tamanho.
        void AjustarJanela()
        {
            if (tamanhoDoQuadro.Width <= 0 || tamanhoDoQuadro.Height <= 0) return;
            double proporcao = (double)tamanhoDoQuadro.Width / tamanhoDoQuadro.Height;
            var novo = proporcao < 1
                ? new Size((int)Math.Round(ladoMaior * proporcao), ladoMaior)
                : new Size(ladoMaior, (int)Math.Round(ladoMaior / proporcao));
            var atual = Bounds;
            var area = Screen.FromControl(this).WorkingArea;
            int x = Math.Min(Math.Max(atual.Right - novo.Width, area.Left), Math.Max(area.Left, area.Right - novo.Width));
            int y = Math.Min(Math.Max(atual.Top, area.Top), Math.Max(area.Top, area.Bottom - novo.Height));
            SetBounds(x, y, novo.Width, novo.Height);
        }

        // ---- UxPlay ----

        void IniciarUxPlay()
        {
            var erro = uxplay.Iniciar(gravando);
            if (erro != null) MostrarAviso("Não consegui iniciar o receptor AirPlay.\n" + erro);
        }

        void UxPlayParou()
        {
            if (encerrando) return;
            if (reiniciandoDeProposito)
            {
                reiniciandoDeProposito = false;
                IniciarUxPlay();
                return;
            }
            tamanhoDoQuadro = Size.Empty;
            if (reinicios < 3)
            {
                reinicios++;
                MostrarAviso("Reiniciando o receptor…");
                Depois(2000, IniciarUxPlay);
            }
            else
            {
                MostrarAviso("O receptor AirPlay parou.\nDetalhes no arquivo Liftstream.log,\nna pasta %LOCALAPPDATA%\\Liftstream.");
            }
        }

        // ---- Desenho ----

        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e)
        {
            Desenhar(e.Graphics, ClientRectangle);
        }

        void Desenhar(Graphics g, Rectangle area)
        {
            g.Clear(Deep);
            if (quadro == null)
            {
                DesenharEspera(g, area);
                return;
            }
            double pq = (double)quadro.Width / quadro.Height;
            double pj = (double)area.Width / Math.Max(1, area.Height);
            int w, h;
            if (pj > pq) { h = area.Height; w = (int)Math.Round(h * pq); }
            else { w = area.Width; h = (int)Math.Round(w / pq); }
            var destino = new Rectangle(area.Left + (area.Width - w) / 2, area.Top + (area.Height - h) / 2, w, h);
            g.InterpolationMode = InterpolationMode.Bilinear;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(quadro, destino);
        }

        void DesenharEspera(Graphics g, Rectangle area)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            float escala = Escala;
            var linhas = (aviso ?? TextoEspera).Split('\n');
            var flags = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.SingleLine;
            var sem = new Size(int.MaxValue, int.MaxValue);

            // Encolhe a letra se a linha mais larga não couber (janela pequena ou mensagem longa).
            float px = 14f * escala;
            float maior = 1;
            using (var medida = new Font("Segoe UI Semibold", px, FontStyle.Regular, GraphicsUnit.Pixel))
                foreach (var l in linhas)
                    maior = Math.Max(maior, TextRenderer.MeasureText(g, l, medida, sem, flags).Width);
            px = Math.Max(8f, px * Math.Min(1f, (area.Width - 32f * escala) / maior));

            using (var normal = new Font("Segoe UI Semibold", px, FontStyle.Regular, GraphicsUnit.Pixel))
            using (var destaque = new Font("Segoe UI", px, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                int altura = normal.Height + (int)Math.Round(3 * escala);
                float larguraLogo = Math.Min(96f * escala, area.Width * 0.6f);
                float alturaLogo = larguraLogo * logo.Height / logo.Width;
                float vao = 22f * escala;
                float total = alturaLogo + vao + altura * linhas.Length;
                float y = area.Top + (area.Height - total) / 2f;
                g.DrawImage(logo, new RectangleF(area.Left + (area.Width - larguraLogo) / 2f, y, larguraLogo, alturaLogo));
                y += alturaLogo + vao;
                foreach (var linha in linhas)
                {
                    DesenharLinha(g, linha, normal, destaque, area, (int)Math.Round(y), flags);
                    y += altura;
                }
            }
        }

        // O nome do programa vai em lime e em negrito; o resto, em branco.
        static void DesenharLinha(Graphics g, string linha, Font normal, Font destaque, Rectangle area, int y, TextFormatFlags flags)
        {
            var textos = new List<string>();
            var fontes = new List<Font>();
            var cores = new List<Color>();
            int i = linha.IndexOf(Config.NomeAirPlay, StringComparison.Ordinal);
            if (i >= 0)
            {
                textos.Add(linha.Substring(0, i)); fontes.Add(normal); cores.Add(Texto);
                textos.Add(Config.NomeAirPlay); fontes.Add(destaque); cores.Add(Lime);
                textos.Add(linha.Substring(i + Config.NomeAirPlay.Length)); fontes.Add(normal); cores.Add(Texto);
            }
            else
            {
                textos.Add(linha); fontes.Add(normal); cores.Add(Texto);
            }
            var sem = new Size(int.MaxValue, int.MaxValue);
            var larguras = new int[textos.Count];
            int total = 0;
            for (int k = 0; k < textos.Count; k++)
            {
                larguras[k] = textos[k].Length == 0 ? 0 : TextRenderer.MeasureText(g, textos[k], fontes[k], sem, flags).Width;
                total += larguras[k];
            }
            int x = area.Left + (area.Width - total) / 2;
            for (int k = 0; k < textos.Count; k++)
            {
                if (textos[k].Length > 0) TextRenderer.DrawText(g, textos[k], fontes[k], new Point(x, y), cores[k], flags);
                x += larguras[k];
            }
        }

        // ---- Arrastar, redimensionar e menu ----

        // O corpo da janela arrasta; as bordas redimensionam. Sem barra de título, é assim que se mexe nela.
        int Acertar(Point p)
        {
            int b = (int)Math.Round(8 * Escala);
            bool esquerda = p.X < b, direita = p.X >= Width - b, cima = p.Y < b, baixo = p.Y >= Height - b;
            if (cima && esquerda) return HTTOPLEFT;
            if (cima && direita) return HTTOPRIGHT;
            if (baixo && esquerda) return HTBOTTOMLEFT;
            if (baixo && direita) return HTBOTTOMRIGHT;
            if (esquerda) return HTLEFT;
            if (direita) return HTRIGHT;
            if (cima) return HTTOP;
            if (baixo) return HTBOTTOM;
            return HTCAPTION;
        }

        // Ao arrastar uma borda, mantém a proporção do quadro do iPhone.
        void ForcarProporcao(IntPtr lParam, int borda)
        {
            if (tamanhoDoQuadro.Width <= 0 || tamanhoDoQuadro.Height <= 0) return;
            var r = (RECT)Marshal.PtrToStructure(lParam, typeof(RECT));
            double proporcao = (double)tamanhoDoQuadro.Width / tamanhoDoQuadro.Height;
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;
            switch (borda)
            {
                case 1: case 2: // esquerda, direita
                    r.Bottom = r.Top + (int)Math.Round(w / proporcao);
                    break;
                case 3: case 6: // cima, baixo
                    r.Right = r.Left + (int)Math.Round(h * proporcao);
                    break;
                case 4: case 5: // cantos de cima
                    r.Top = r.Bottom - (int)Math.Round(w / proporcao);
                    break;
                case 7: case 8: // cantos de baixo
                    r.Bottom = r.Top + (int)Math.Round(w / proporcao);
                    break;
            }
            Marshal.StructureToPtr(r, lParam, false);
        }

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_NCHITTEST:
                    {
                        long lp = m.LParam.ToInt64();
                        var tela = new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF));
                        m.Result = (IntPtr)Acertar(PointToClient(tela));
                        return;
                    }
                case WM_NCRBUTTONUP:
                    menu.Show(Cursor.Position);
                    m.Result = IntPtr.Zero;
                    return;
                case WM_CONTEXTMENU: // sem o menu do sistema (Restaurar, Mover, Tamanho...)
                    return;
                case WM_NCLBUTTONDBLCLK: // duplo clique no corpo maximizaria a janela
                    return;
                case WM_SIZING:
                    ForcarProporcao(m.LParam, m.WParam.ToInt32());
                    m.Result = (IntPtr)1;
                    return;
            }
            base.WndProc(ref m);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (WindowState == FormWindowState.Normal && Width > 0) ladoMaior = Math.Max(Width, Height);
        }

        void MontarMenu()
        {
            menu = new ContextMenuStrip();

            itemFrente = new ToolStripMenuItem("Sempre na frente") { Checked = true };
            itemFrente.Click += (s, e) =>
            {
                itemFrente.Checked = !itemFrente.Checked;
                TopMost = itemFrente.Checked;
            };
            menu.Items.Add(itemFrente);

            itemCliques = new ToolStripMenuItem("Deixar os cliques passarem")
            {
                ToolTipText = "Com isto ligado a janela não recebe o mouse. Para desligar, use o ícone do Liftstream ao lado do relógio."
            };
            itemCliques.Click += (s, e) => AlternarCliques();
            menu.Items.Add(itemCliques);
            menu.Items.Add(new ToolStripSeparator());

            var tamanho = new ToolStripMenuItem("Tamanho");
            var nomes = new[] { "Pequeno", "Médio", "Grande" };
            var lados = new[] { 480, 640, 900 };
            for (int i = 0; i < nomes.Length; i++)
            {
                int lado = lados[i];
                var item = new ToolStripMenuItem(nomes[i]);
                item.Click += (s, e) => EscolherTamanho(lado);
                tamanho.DropDownItems.Add(item);
            }
            menu.Items.Add(tamanho);

            var opacidade = new ToolStripMenuItem("Opacidade");
            foreach (int valor in new[] { 100, 85, 70, 50 })
            {
                int porcento = valor;
                var item = new ToolStripMenuItem(porcento + "%") { Checked = porcento == 100 };
                item.Click += (s, e) =>
                {
                    foreach (ToolStripMenuItem outro in opacidade.DropDownItems) outro.Checked = ReferenceEquals(outro, item);
                    Opacity = porcento >= 100 ? 0.999 : porcento / 100.0;
                };
                opacidade.DropDownItems.Add(item);
            }
            menu.Items.Add(opacidade);
            menu.Items.Add(new ToolStripSeparator());

            itemGravar = new ToolStripMenuItem("Gravar em MP4 (com som do iPhone)");
            itemGravar.Click += (s, e) => AlternarGravacao();
            menu.Items.Add(itemGravar);
            var abrir = new ToolStripMenuItem("Abrir pasta das gravações");
            abrir.Click += (s, e) => AbrirGravacoes();
            menu.Items.Add(abrir);
            menu.Items.Add(new ToolStripSeparator());

            var verificar = new ToolStripMenuItem("Verificar atualizações…");
            verificar.Click += (s, e) => VerificarAtualizacao(true);
            menu.Items.Add(verificar);
            var sobre = new ToolStripMenuItem("Sobre o Liftstream");
            sobre.Click += (s, e) => MessageBox.Show(this,
                "Liftstream " + Config.Versao + "\nClínica Lifts · saúde 100% online\n\nhttps://github.com/" + Config.Repositorio,
                "Sobre o Liftstream", MessageBoxButtons.OK, MessageBoxIcon.Information);
            menu.Items.Add(sobre);
            menu.Items.Add(new ToolStripSeparator());
            var sair = new ToolStripMenuItem("Sair do Liftstream");
            sair.Click += (s, e) => Close();
            menu.Items.Add(sair);

            // O ícone da bandeja tem o mesmo menu: com "deixar os cliques passarem" ligado é o único jeito de alcançá-lo.
            bandeja = new NotifyIcon
            {
                Icon = Icon ?? SystemIcons.Application,
                Text = Config.NomeAirPlay,
                ContextMenuStrip = menu,
                Visible = true,
            };
            bandeja.MouseClick += (s, e) =>
            {
                if (e.Button == MouseButtons.Left) TrazerParaFrente();
            };
        }

        void TrazerParaFrente()
        {
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
            bool antes = TopMost;
            TopMost = true;
            TopMost = antes;
        }

        void AlternarCliques()
        {
            cliquesPassam = !cliquesPassam;
            itemCliques.Checked = cliquesPassam;
            UpdateStyles();
        }

        void EscolherTamanho(int pixels)
        {
            ladoMaior = (int)Math.Round(pixels * Escala);
            if (tamanhoDoQuadro.IsEmpty)
            {
                var atual = Bounds;
                var novo = new Size((int)Math.Round(ladoMaior * 0.46), ladoMaior);
                SetBounds(atual.Right - novo.Width, atual.Top, novo.Width, novo.Height);
            }
            else
            {
                AjustarJanela();
            }
        }

        void AlternarGravacao()
        {
            gravando = !gravando;
            itemGravar.Checked = gravando;
            reiniciandoDeProposito = true;
            IphoneSaiu();
            MostrarAviso((gravando ? "Gravação ligada." : "Gravação desligada.") + "\nEspelhe de novo pelo iPhone.\n\n" + TextoEspera);
            if (uxplay.Rodando) uxplay.Parar(false);
            else UxPlayParou();
        }

        static void AbrirGravacoes()
        {
            try
            {
                Directory.CreateDirectory(Config.Gravacoes);
                Process.Start(new ProcessStartInfo(Config.Gravacoes) { UseShellExecute = true });
            }
            catch { }
        }

        // ---- Atualização ----

        // Sozinho, consulta no máximo a cada 20 horas e só fala se houver versão nova; pelo menu, sempre responde.
        void VerificarAtualizacao(bool manual)
        {
            var arquivo = Path.Combine(Config.Dados, "ultimaChecagem.txt");
            if (!manual && pastaCaptura == null)
            {
                try
                {
                    long ultima;
                    if (File.Exists(arquivo) && long.TryParse(File.ReadAllText(arquivo).Trim(), out ultima)
                        && DateTimeOffset.UtcNow.ToUnixTimeSeconds() - ultima < 20 * 3600) return;
                }
                catch { }
            }
            Atualizacoes.Consultar((ok, nova) => UI(() =>
            {
                if (ok && pastaCaptura == null)
                {
                    try { File.WriteAllText(arquivo, DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString()); } catch { }
                }
                if (pastaCaptura != null)
                {
                    EscreverCaptura("atualizacao.txt", !ok ? "falha" : nova == null ? "em dia" : "nova " + nova.Numero);
                    return;
                }
                if (ok && nova != null) Oferecer(nova);
                else if (manual)
                    MessageBox.Show(this,
                        ok ? "O Liftstream " + Config.Versao + " é o último." : "Confira a conexão com a internet e tente de novo.",
                        ok ? "Você está na versão mais recente" : "Não consegui verificar",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
            }));
        }

        void Oferecer(VersaoNova nova)
        {
            if (atualizacaoAberta) return;
            atualizacaoAberta = true;
            try
            {
                var notas = nova.Notas.Length == 0 ? "" : "\n\n" + (nova.Notas.Length > 400 ? nova.Notas.Substring(0, 400) : nova.Notas);
                var resposta = MessageBox.Show(this,
                    "Você está na " + Config.Versao + " e a nova é a " + nova.Numero + "." + notas + "\n\nBaixar agora?",
                    "Tem uma versão nova do Liftstream", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (resposta == DialogResult.Yes)
                {
                    try { Process.Start(new ProcessStartInfo(nova.Endereco.ToString()) { UseShellExecute = true }); } catch { }
                }
            }
            finally { atualizacaoAberta = false; }
        }

        // ---- Teste automático (CI) ----
        // Com LIFTSTREAM_CAPTURA=<pasta> o app salva imagens do que desenharia e sai sozinho.

        void IniciarCaptura()
        {
            try { Directory.CreateDirectory(pastaCaptura); } catch { }
            Depois(6000, () => Capturar("espera.png"));
            Depois(120000, () =>
            {
                EscreverCaptura("erro.txt", "nenhum quadro em 120 s");
                Application.Exit();
            });
        }

        void Capturar(string nome)
        {
            try
            {
                using (var imagem = new Bitmap(Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height)))
                {
                    using (var g = Graphics.FromImage(imagem)) Desenhar(g, new Rectangle(0, 0, imagem.Width, imagem.Height));
                    imagem.Save(Path.Combine(pastaCaptura, nome), ImageFormat.Png);
                }
            }
            catch (Exception e) { EscreverCaptura("erro-" + nome + ".txt", e.ToString()); }
        }

        void EscreverCaptura(string nome, string texto)
        {
            try { File.WriteAllText(Path.Combine(pastaCaptura, nome), texto); } catch { }
        }
    }
}
