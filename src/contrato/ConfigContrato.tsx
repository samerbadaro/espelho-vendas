// Cadastro do empreendimento para contratos (somente administrador):
// dados da vendedora/registros/textos e importação do quadro de áreas (planilha .xlsx ou .csv).
import { useEffect, useMemo, useRef, useState } from 'react';
import { FileSpreadsheet, Download } from 'lucide-react';
import { unzipSync, strFromU8 } from 'fflate';
import { supabase, formatarDataHora } from '../dados';
import { useDialogos } from '../ui';
import { CAMPOS_EMPREENDIMENTO, COLUNAS_AREAS, DADOS_EXEMPLO, type Areas } from './campos';

const semAcento = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '');
const NUMERICAS = new Set(['area_privativa', 'area_acessoria', 'area_privativa_total', 'area_comum', 'area_total', 'fracao_ideal', 'escaninho_area']);

/** Lê a primeira aba de um .xlsx como matriz de textos. */
function lerXlsx(buf: ArrayBuffer): string[][] {
  const z = unzipSync(new Uint8Array(buf));
  const xml = (n: string) => (z[n] ? new DOMParser().parseFromString(strFromU8(z[n]), 'application/xml') : null);
  const comp = xml('xl/sharedStrings.xml');
  const strings = comp ? [...comp.getElementsByTagName('si')].map((si) => [...si.getElementsByTagName('t')].map((t) => t.textContent ?? '').join('')) : [];
  const nomeAba = Object.keys(z).filter((n) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n)).sort((a, b) => Number(a.match(/\d+/g)!.pop()) - Number(b.match(/\d+/g)!.pop()))[0];
  const aba = nomeAba ? xml(nomeAba) : null;
  if (!aba) throw new Error('Não encontrei a planilha dentro do arquivo.');
  const col = (ref: string) => ref.replace(/\d+/g, '').split('').reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0) - 1;
  return [...aba.getElementsByTagName('row')].map((row) => {
    const linha: string[] = [];
    for (const c of [...row.getElementsByTagName('c')]) {
      const t = c.getAttribute('t'), v = c.getElementsByTagName('v')[0]?.textContent ?? '';
      const val = t === 's' ? strings[Number(v)] ?? '' : t === 'inlineStr' ? [...c.getElementsByTagName('t')].map((x) => x.textContent).join('') : v;
      linha[col(c.getAttribute('r') ?? 'A1')] = val;
    }
    return Array.from(linha, (x) => x ?? '');
  });
}

function lerCsv(txt: string): string[][] {
  const linhas = txt.replace(/^﻿/, '').split(/\r?\n/).filter((l) => l.trim());
  const sep = (linhas[0].match(/;/g)?.length ?? 0) >= (linhas[0].match(/,/g)?.length ?? 0) ? ';' : ',';
  return linhas.map((l) => {
    const out: string[] = []; let atual = '', aspas = false;
    for (const ch of l) {
      if (ch === '"') aspas = !aspas;
      else if (ch === sep && !aspas) { out.push(atual); atual = ''; }
      else atual += ch;
    }
    out.push(atual);
    return out.map((s) => s.trim());
  });
}

const numero = (s: string) => {
  const t = s.trim().replace(/\s|m²/g, '');
  if (!t) return null;
  const pct = t.endsWith('%');
  // vírgula = decimal brasileiro (CSV); sem vírgula = número cru (xlsx ou CSV com ponto)
  const n = Number((t.includes(',') ? t.replace(/\./g, '').replace(',', '.') : t).replace('%', ''));
  return Number.isFinite(n) ? (pct ? n / 100 : n) : NaN;
};

/** Converte a matriz da planilha em linhas do quadro de áreas, reconhecendo o cabeçalho. */
export function linhasDoQuadro(m: string[][]): { linhas: Areas[]; erros: string[] } {
  const iCab = m.findIndex((l) => l.some((c) => ['unidade', 'numero', 'identificador'].includes(semAcento(c))));
  if (iCab < 0) return { linhas: [], erros: ['Não achei a coluna "Unidade" no cabeçalho.'] };
  const mapa = m[iCab].map((c) => {
    const n = semAcento(c);
    if (n === 'identificador' || n === 'numero') return 'numero';
    return COLUNAS_AREAS.find(([k, r]) => semAcento(r) === n || semAcento(k) === n)?.[0] ?? null;
  });
  const erros: string[] = [];
  const linhas = m.slice(iCab + 1).filter((l) => l.some((c) => c.trim())).map((l, i) => {
    const a: Areas = {};
    mapa.forEach((k, j) => {
      if (!k) return;
      const v = (l[j] ?? '').trim();
      if (NUMERICAS.has(k)) {
        const n = numero(v);
        if (Number.isNaN(n)) erros.push(`Linha ${iCab + i + 2}: "${v}" não é número (${k}).`);
        a[k] = n == null || Number.isNaN(n) ? null : n;
      } else a[k] = v;
    });
    if (!a.numero) erros.push(`Linha ${iCab + i + 2}: sem número da unidade.`);
    return a;
  });
  return { linhas, erros };
}

function baixarModelo() {
  const cab = COLUNAS_AREAS.map(([, r]) => r).join(';');
  const ex = ['206', 'Torre Única', '2º PAVIMENTO', '34,93', '12,00', '46,93', '17,83', '64,76', '0,0057801', 'Vaga 12 / Subsolo 1', 'E-03', 'Subsolo 1', '2,50'].join(';');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([`﻿${cab}\n${ex}\n`], { type: 'text/csv;charset=utf-8' }));
  a.download = 'modelo_quadro_de_areas.csv'; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

export function ConfigContrato() {
  const { avisar, confirmar } = useDialogos();
  const [dados, setDados] = useState<Record<string, string> | null>(null);
  const [info, setInfo] = useState<{ em: string; por: string | null } | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [qtdAreas, setQtdAreas] = useState<number | null>(null);
  const [amostra, setAmostra] = useState<Areas[]>([]);
  const arquivo = useRef<HTMLInputElement>(null);

  const carregar = async () => {
    const { data } = await supabase.from('empreendimento_contrato').select('*').maybeSingle();
    setDados((data?.dados as Record<string, string>) ?? {});
    setInfo(data ? { em: data.atualizado_em, por: data.atualizado_por } : null);
    const { count } = await supabase.from('unidade_areas').select('numero', { count: 'exact', head: true });
    setQtdAreas(count ?? 0);
    const { data: am } = await supabase.from('unidade_areas').select('*').order('numero').limit(5);
    setAmostra((am as Areas[]) ?? []);
  };
  useEffect(() => { carregar(); }, []);

  const grupos = useMemo(() => [...new Set(CAMPOS_EMPREENDIMENTO.map((c) => c.grupo))], []);
  if (!dados) return null;
  const vazios = CAMPOS_EMPREENDIMENTO.filter((c) => !dados[c.chave]?.trim()).length;

  const salvar = async () => {
    setSalvando(true);
    const { error } = await supabase.rpc('salvar_empreendimento_contrato', { p_dados: dados });
    setSalvando(false);
    if (error) { avisar('Não foi possível salvar os dados do contrato.', 'erro'); return; }
    avisar('Dados para contrato salvos.'); carregar();
  };

  const importar = async (f: File) => {
    try {
      const m = /\.xlsx$/i.test(f.name) ? lerXlsx(await f.arrayBuffer()) : lerCsv(await f.text());
      const { linhas, erros } = linhasDoQuadro(m);
      if (erros.length) { avisar(erros.slice(0, 3).join(' '), 'erro'); return; }
      if (!linhas.length) { avisar('A planilha não tem unidades.', 'erro'); return; }
      if (!(await confirmar({ titulo: `Importar ${linhas.length} unidades?`, texto: 'O quadro de áreas atual será substituído inteiro por esta planilha.', confirmar: 'Importar' }))) return;
      const { data, error } = await supabase.rpc('importar_quadro_areas', { p_linhas: linhas });
      if (error) { avisar(error.message.includes('REPETIDA') ? 'Há unidade repetida na planilha.' : 'Não foi possível importar a planilha.', 'erro'); return; }
      avisar(`${data} unidades importadas.`); carregar();
    } catch (e) {
      avisar((e as Error).message || 'Não consegui ler o arquivo.', 'erro');
    } finally { if (arquivo.current) arquivo.current.value = ''; }
  };

  return (
    <>
      <div className="cartao">
        <div className="cartao-topo">
          <div>
            <h3>Dados para contrato</h3>
            <p className="sub">Vendedora, registros e textos que entram no Quadro Resumo e nas Normas Contratuais.
              {info && <> Atualizado por {info.por ?? '—'} em {formatarDataHora(info.em)}.</>}</p>
          </div>
          {vazios > 0 && <span className="selo sp-pendente_correcao">{vazios} em branco</span>}
        </div>
        {grupos.map((g) => (
          <fieldset key={g} className="dc-pessoa">
            <legend>{g}</legend>
            <div className="dc-grade">
              {CAMPOS_EMPREENDIMENTO.filter((c) => c.grupo === g).map((c) => (
                <label key={c.chave} className={c.longo ? 'dc-inteiro' : ''}>
                  <span>{c.rotulo}</span>
                  {c.longo
                    ? <textarea rows={2} value={dados[c.chave] ?? ''} onChange={(e) => setDados({ ...dados, [c.chave]: e.target.value })} />
                    : <input value={dados[c.chave] ?? ''} onChange={(e) => setDados({ ...dados, [c.chave]: e.target.value })} />}
                </label>
              ))}
            </div>
          </fieldset>
        ))}
        <div className="acoes">
          <button type="button" className="botao" onClick={() => setDados({ ...DADOS_EXEMPLO, ...Object.fromEntries(Object.entries(dados).filter(([, v]) => v?.trim())) })}>Completar com dados fictícios</button>
          <button type="button" className="botao principal" onClick={salvar} disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar dados para contrato'}</button>
        </div>
      </div>

      <div className="cartao">
        <div className="cartao-topo">
          <div>
            <h3>Quadro de áreas</h3>
            <p className="sub">Áreas, fração ideal, pavimento, vagas e escaninho de cada unidade, usados no item 3 do Quadro Resumo.
              {' '}{qtdAreas ? `${qtdAreas} unidades cadastradas.` : 'Nenhuma unidade cadastrada ainda.'}</p>
          </div>
        </div>
        {amostra.length > 0 && (
          <div className="tabela-rolagem">
            <table className="tabela dc-areas">
              <thead><tr>{COLUNAS_AREAS.map(([k, r]) => <th key={k}>{r}</th>)}</tr></thead>
              <tbody>{amostra.map((a) => <tr key={String(a.numero)}>{COLUNAS_AREAS.map(([k]) => <td key={k}>{a[k] == null ? '—' : String(a[k])}</td>)}</tr>)}</tbody>
            </table>
            <p className="sub">Mostrando as 5 primeiras.</p>
          </div>
        )}
        <div className="acoes">
          <button type="button" className="botao" onClick={baixarModelo}><Download size={16} /> Baixar modelo da planilha</button>
          <button type="button" className="botao principal" onClick={() => arquivo.current?.click()}><FileSpreadsheet size={16} /> Importar planilha (.xlsx ou .csv)</button>
          <input ref={arquivo} type="file" hidden accept=".xlsx,.csv" onChange={(e) => e.target.files?.[0] && importar(e.target.files[0])} />
        </div>
      </div>
    </>
  );
}
