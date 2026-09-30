#!/usr/bin/env python3
"""Copia para dentro do app o GStreamer (e tudo de que o UxPlay depende) que está no Homebrew.

Uso: embutir.py "<app>" [--extra <executável> ...] [--plugin <nome> ...]
  --extra: executáveis a mais em Contents/Helpers (só para testar a cópia).
  --plugin: plugins a mais (só para testar a cópia, ex.: videotestsrc).

Bibliotecas vão para Contents/Frameworks, plugins para Contents/Helpers/plugins (o codesign toma por pacote pasta com ponto no nome, como gstreamer-1.0),
e os caminhos /opt/homebrew são trocados por caminhos relativos ao arquivo.
"""
import os
import re
import shutil
import subprocess
import sys

BREW = "/opt/homebrew/opt/gstreamer"
SCANNER = BREW + "/libexec/gstreamer-1.0/gst-plugin-scanner"

# Um plugin por elemento que o UxPlay e o app usam (ver "Plugins" no CLAUDE.md).
PLUGINS = """app applemedia audioconvert audioparsers audioresample autodetect coreelements imagefreeze
isomp4 jpeg level libav multipart osxaudio pango playback tcp typefindfunctions videoconvertscale
videofilter videoparsersbad volume""".split()


def sh(*cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("falhou: " + " ".join(cmd) + "\n" + r.stderr)
    return r.stdout


def deps_de(path):
    return [l.strip().split(" (")[0] for l in sh("otool", "-L", path).splitlines()[1:]]


def rpaths_de(path):
    linhas = sh("otool", "-l", path).splitlines()
    achados = []
    for i, l in enumerate(linhas):
        if l.strip() == "cmd LC_RPATH":
            achados.append(re.search(r"path (.+) \(offset", linhas[i + 2]).group(1))
    return achados


def resolver(dep, origem):
    if dep.startswith(("/usr/lib/", "/System/")):
        return None
    pasta = os.path.dirname(os.path.realpath(origem))
    if dep.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(pasta, dep[len("@loader_path/"):]))
    if dep.startswith("@rpath/"):
        for rp in rpaths_de(origem):
            cand = os.path.join(rp.replace("@loader_path", pasta), dep[len("@rpath/"):])
            if os.path.exists(cand):
                return os.path.realpath(cand)
        sys.exit(f"não achei {dep} (pedido por {origem})")
    if dep.startswith("/"):
        return os.path.realpath(dep)
    sys.exit(f"caminho que não sei resolver: {dep} (pedido por {origem})")


def escrever_avisos(app, copias):
    """Lista o que foi embutido, com licença e onde está o código-fonte de cada peça (GPL e LGPL pedem isso)."""
    import json
    aqui = os.path.dirname(os.path.abspath(__file__))
    formulas = {}
    for original in copias:
        m = re.search(r"/Cellar/([^/]+)/([^/]+)/", original)
        if m:
            formulas[m.group(1)] = m.group(2)
    info = json.loads(sh("brew", "info", "--json=v2", *sorted(formulas)))["formulae"]
    commit = open(f"{aqui}/UXPLAY_COMMIT").read().strip()
    linhas = [
        "AVISOS DE TERCEIROS · Liftstream",
        "",
        "O Liftstream é distribuído sob a GPL-3.0 (arquivo LICENSE; código em https://github.com/edsonlifts/liftstream).",
        "Ele leva dentro de si os programas abaixo, cada um sob a própria licença. Em cada linha estão a versão",
        "embutida, a licença, a página do projeto e o endereço do código-fonte dessa versão.",
        "",
        f"UxPlay · GPL-3.0 · https://github.com/FDH2/UxPlay · commit {commit}",
        f"    código-fonte: https://github.com/FDH2/UxPlay/tree/{commit}",
        "",
    ]
    for f in sorted(info, key=lambda x: x["name"]):
        licenca = f.get("license") or "ver a página do projeto"
        embutida = re.sub(r"_\d+$", "", formulas[f["name"]])
        atual = f["versions"]["stable"]
        fonte = (f.get("urls", {}).get("stable") or {}).get("url", f["homepage"])
        # A fórmula do Homebrew aponta para a versão mais nova; o aviso tem de apontar para a embutida.
        if atual != embutida and atual in fonte:
            fonte = fonte.replace(atual, embutida)
        linhas += [f"{f['name']} {embutida} · {licenca} · {f['homepage']}", f"    código-fonte: {fonte}"]
    with open(f"{app}/Contents/Resources/AVISOS-DE-TERCEIROS.txt", "w") as saida:
        saida.write("\n".join(linhas) + "\n")


def main():
    args = sys.argv[1:]
    app = args.pop(0)
    extras = []
    mais_plugins = []
    while args:
        opcao = args.pop(0)
        if opcao == "--extra":
            extras.append(args.pop(0))
        elif opcao == "--plugin":
            mais_plugins.append(args.pop(0))

    helpers = f"{app}/Contents/Helpers"
    frameworks = f"{app}/Contents/Frameworks"
    pasta_plugins = f"{helpers}/plugins"
    shutil.rmtree(frameworks, ignore_errors=True)
    shutil.rmtree(pasta_plugins, ignore_errors=True)
    os.makedirs(pasta_plugins)
    os.makedirs(frameworks, exist_ok=True)

    # Executáveis: já no app (uxplay) ou copiados do Homebrew.
    executaveis = [f"{helpers}/uxplay"]
    for origem in [SCANNER] + extras:
        destino = f"{helpers}/{os.path.basename(origem)}"
        shutil.copy2(os.path.realpath(origem), destino)
        os.chmod(destino, 0o755)
        executaveis.append(destino)

    plugins = {}  # original -> cópia
    for nome in PLUGINS + mais_plugins:
        origem = os.path.realpath(f"{BREW}/lib/gstreamer-1.0/libgst{nome}.dylib")
        if not os.path.exists(origem):
            sys.exit(f"falta o plugin {nome} no Homebrew")
        plugins[origem] = f"{pasta_plugins}/{os.path.basename(origem)}"

    # Fecho das dependências a partir dos executáveis e dos plugins.
    bibliotecas = {}  # original -> cópia
    fila = [(e, e) for e in executaveis] + [(o, o) for o in plugins]
    vistos = set()
    while fila:
        original, lido = fila.pop()
        if original in vistos:
            continue
        vistos.add(original)
        for dep in deps_de(lido):
            r = resolver(dep, original)
            if r is None or r in vistos:
                continue
            if r not in plugins:
                nome = os.path.basename(r)
                destino = f"{frameworks}/{nome}"
                if destino in bibliotecas.values() and bibliotecas.get(r) != destino:
                    sys.exit(f"dois arquivos com o nome {nome}")
                bibliotecas[r] = destino
            fila.append((r, r))

    copias = {**bibliotecas, **plugins}
    for original, destino in copias.items():
        shutil.copy2(original, destino)
        os.chmod(destino, 0o755)

    # Troca os caminhos: todo arquivo aponta para as cópias, relativo a si mesmo.
    alvos = [(e, e) for e in executaveis] + [(o, c) for o, c in copias.items()]
    for original, copia in alvos:
        pasta = os.path.dirname(copia)
        comando = ["install_name_tool"]
        for dep in deps_de(copia):
            r = resolver(dep, original)
            if r is None:
                continue
            novo = copias[r]
            comando += ["-change", dep, "@loader_path/" + os.path.relpath(novo, pasta)]
        for rp in rpaths_de(copia):
            comando += ["-delete_rpath", rp]
        if copia.endswith(".dylib"):
            comando += ["-id", "@loader_path/" + os.path.basename(copia)]
        sh(*comando, copia)

    # Nada pode ter ficado apontando para fora do app.
    for _, copia in alvos:
        for dep in deps_de(copia):
            if not dep.startswith(("/usr/lib/", "/System/", "@loader_path/")):
                sys.exit(f"{copia} ainda aponta para {dep}")
        if rpaths_de(copia):
            sys.exit(f"{copia} ainda tem rpath")

    # Trocar os caminhos invalida a assinatura; no Apple Silicon isso impede de abrir.
    for _, copia in alvos:
        sh("codesign", "-s", "-", "--force", copia)

    escrever_avisos(app, copias)

    total = sum(os.path.getsize(c) for _, c in alvos)
    print(f"{len(bibliotecas)} bibliotecas, {len(plugins)} plugins, {total / 1e6:.0f} MB embutidos")


main()
