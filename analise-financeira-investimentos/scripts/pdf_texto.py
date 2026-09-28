"""Extrai o texto de um PDF simples sem instalar nada (usa só a biblioteca padrão do Python).

Uso: python pdf_texto.py caminho/arquivo.pdf

Serve para ler formulários e lâminas de fundos enviados pelo investidor quando não há
leitor de PDF disponível. Funciona com PDFs cujo texto é digital. PDFs escaneados (imagem)
não têm texto para extrair: nesse caso, peça ao investidor para copiar os dados principais.
Nunca instale pacotes sem pedir permissão ao investidor.
"""
import re
import sys
import zlib


def extrair(caminho):
    dados = open(caminho, "rb").read()
    partes = []
    for fluxo in re.findall(rb"stream\r?\n(.*?)\r?\nendstream", dados, re.S):
        try:
            bruto = zlib.decompress(fluxo)
        except Exception:
            continue
        if b"BT" not in bruto:
            continue
        for a, b in re.findall(rb"\((.*?)(?<!\\)\)\s*Tj|\[(.*?)\]\s*TJ", bruto, re.S):
            partes.append(a if a else b"".join(re.findall(rb"\((.*?)(?<!\\)\)", b, re.S)))
    texto = b"".join(partes).decode("cp1252", "replace")
    return texto.replace("\\(", "(").replace("\\)", ")")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    saida = extrair(sys.argv[1])
    if not saida.strip():
        print("Sem texto extraível (PDF escaneado ou com fontes codificadas). Peça os dados ao investidor.")
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        print(saida)
