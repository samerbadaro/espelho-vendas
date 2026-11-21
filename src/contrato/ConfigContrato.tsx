// Cadastro do empreendimento para contratos (somente administrador):
// dados da vendedora/registros/textos e importação do quadro de áreas (planilha .xlsx ou .csv).
import { useEffect, useMemo, useRef, useState } from 'react';
import { FileSpreadsheet, Download, FileUp, Copy, RotateCcw, ArrowUp, ArrowDown } from 'lucide-react';
import { unzipSync, strFromU8 } from 'fflate';
import { supabase, formatarDataHora } from '../dados';
import { useDialogos } from '../ui';
import { CAMPOS_EMPREENDIMENTO, COLUNAS_AREAS, DADOS_EXEMPLO, type Areas } from './campos';
import { NOME_DOCUMENTO, type TipoDocumento } from './gerador';
import { MARCADORES, conferirModelo, contextoExemplo, dadosParaModelo } from './marcadores';

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
      <ModelosContrato />
      <DocumentosFixos />
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

interface Modelo { id: string; documento: TipoDocumento; nome: string; caminho: string; enviado_em: string; enviado_por: string | null }
const DOCX = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const salvarArquivo = (blob: Blob, nome: string) => {
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = nome; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
};

/** Modelos em Word com marcadores: baixar o atual, enviar o do jurídico, voltar ao padrão, lista de marcadores. */
function ModelosContrato() {
  const { avisar, confirmar } = useDialogos();
  const [ativos, setAtivos] = useState<Partial<Record<TipoDocumento, Modelo>>>({});
  const [ocupado, setOcupado] = useState('');
  const [verMarcadores, setVerMarcadores] = useState(false);
  const [busca, setBusca] = useState('');

  const carregar = async () => {
    const { data } = await supabase.from('modelos_contrato').select('*').eq('ativo', true);
    setAtivos(Object.fromEntries(((data as Modelo[]) ?? []).map((m) => [m.documento, m])));
  };
  useEffect(() => { carregar(); }, []);

  const exemplos = useMemo(() => {
    const d = dadosParaModelo(contextoExemplo());
    const pegar = (t: string) => t.split('.').reduce<unknown>((o, k) => (o == null ? undefined : (o as Record<string, unknown>)[k]), d);
    return Object.fromEntries(MARCADORES.map((m) => {
      const v = pegar(m.tag);
      return [m.tag, Array.isArray(v) ? `${v.length} item(ns)` : typeof v === 'boolean' ? (v ? 'sim' : 'não') : String(v ?? '')];
    }));
  }, []);

  const baixar = async (t: TipoDocumento) => {
    setOcupado(t);
    try {
      const m = ativos[t];
      if (m) {
        const { data, error } = await supabase.storage.from('contratos').download(m.caminho);
        if (error || !data) throw new Error('Não foi possível baixar o modelo.');
        salvarArquivo(data, `Modelo - ${NOME_DOCUMENTO[t]}.docx`);
      } else {
        const { modeloPadrao } = await import('./modeloBase');
        salvarArquivo(await modeloPadrao(t), `Modelo padrão - ${NOME_DOCUMENTO[t]}.docx`);
      }
    } catch (e) { avisar((e as Error).message, 'erro'); }
    finally { setOcupado(''); }
  };

  const enviar = async (t: TipoDocumento, f: File) => {
    if (!/\.docx$/i.test(f.name)) { avisar('O modelo precisa ser um arquivo Word (.docx).', 'erro'); return; }
    setOcupado(t);
    try {
      const buf = await f.arrayBuffer();
      const c = await conferirModelo(buf);
      if (c.erros.length) { avisar(`O modelo tem erro de marcação: ${c.erros.slice(0, 3).join(' · ')}`, 'erro'); return; }
      const texto = c.desconhecidos.length
        ? `Atenção: ${c.desconhecidos.length} marcador(es) não existem e sairão em branco: ${c.desconhecidos.slice(0, 8).map((x) => `{${x}}`).join(', ')}. Envie mesmo assim?`
        : `${c.usados} marcador(es) reconhecido(s). O modelo passa a valer nas próximas emissões.`;
      if (!(await confirmar({ titulo: `Usar este modelo para ${NOME_DOCUMENTO[t]}?`, texto, confirmar: 'Usar modelo' }))) return;
      const caminho = `modelos/${t}/${crypto.randomUUID()}.docx`;
      const up = await supabase.storage.from('contratos').upload(caminho, f, { contentType: DOCX });
      if (up.error) throw new Error('Falha ao guardar o modelo.');
      const { error } = await supabase.rpc('salvar_modelo_contrato', { p_documento: t, p_nome: f.name, p_caminho: caminho });
      if (error) throw new Error('Não foi possível ativar o modelo.');
      avisar('Modelo ativado.'); carregar();
    } catch (e) { avisar((e as Error).message, 'erro'); }
    finally { setOcupado(''); }
  };

  const padrao = async (t: TipoDocumento) => {
    if (!(await confirmar({ titulo: `Voltar ao modelo padrão em ${NOME_DOCUMENTO[t]}?`, texto: 'O modelo enviado sai de uso, mas fica guardado no histórico.', confirmar: 'Voltar ao padrão' }))) return;
    const { error } = await supabase.rpc('usar_modelo_padrao', { p_documento: t });
    if (error) avisar('Não foi possível alterar.', 'erro'); else { avisar('Usando o modelo padrão.'); carregar(); }
  };

  const filtrados = MARCADORES.filter((m) => !busca.trim() || `${m.tag} ${m.descricao} ${m.grupo}`.toLowerCase().includes(busca.trim().toLowerCase()));
  const grupos = [...new Set(filtrados.map((m) => m.grupo))];

  return (
    <div className="cartao">
      <div className="cartao-topo">
        <div>
          <h3>Modelos de contrato (Word)</h3>
          <p className="sub">Baixe o modelo, edite no Word (texto, formatação, logo) mantendo os marcadores entre chaves, como {'{comprador.nome}'}, e envie de volta.</p>
        </div>
      </div>
      {(Object.keys(NOME_DOCUMENTO) as TipoDocumento[]).map((t) => {
        const m = ativos[t];
        return (
          <div key={t} className="mc-linha">
            <div>
              <strong>{NOME_DOCUMENTO[t]}</strong><br />
              <small className="sub">{m ? <>{m.nome} · enviado por {m.enviado_por ?? '—'} em {formatarDataHora(m.enviado_em)}</> : 'Modelo padrão do sistema'}</small>
            </div>
            <div className="mc-acoes">
              <button type="button" className="botao pequeno" disabled={!!ocupado} onClick={() => baixar(t)}><Download size={14} /> Baixar modelo</button>
              <label className="botao pequeno"><FileUp size={14} /> {ocupado === t ? 'Conferindo…' : 'Enviar modelo'}
                <input type="file" hidden accept=".docx" disabled={!!ocupado} onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) enviar(t, f); }} />
              </label>
              {m && <button type="button" className="botao pequeno" onClick={() => padrao(t)}><RotateCcw size={14} /> Usar o padrão</button>}
            </div>
          </div>
        );
      })}
      <div className="acoes">
        <button type="button" className="botao" onClick={() => setVerMarcadores(!verMarcadores)}>{verMarcadores ? 'Esconder marcadores' : `Ver os ${MARCADORES.length} marcadores disponíveis`}</button>
      </div>
      {verMarcadores && (
        <div className="mc-marcadores">
          <label className="busca-funil"><input type="search" placeholder="Buscar marcador" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
          <p className="sub">Listas e condições usam abertura e fechamento: {'{#series}'} … {'{/series}'}, {'{#tem_conjuge}'} … {'{/tem_conjuge}'}. Para repetir parágrafos, deixe a abertura e o fechamento sozinhos no próprio parágrafo; para repetir linhas de tabela, coloque a abertura na primeira célula e o fechamento na última.</p>
          {grupos.map((g) => (
            <div key={g}>
              <h4 className="ct-sub">{g}</h4>
              <table className="tabela mc-tabela"><tbody>
                {filtrados.filter((m) => m.grupo === g).map((m) => (
                  <tr key={m.tag}>
                    <td className="mono">{`{${m.lista ? '#' : ''}${m.tag}}`}
                      <button type="button" className="botao pequeno mc-copiar" title="Copiar" onClick={() => { navigator.clipboard?.writeText(`{${m.lista ? '#' : ''}${m.tag}}`); avisar('Marcador copiado.'); }}><Copy size={12} /></button></td>
                    <td>{m.descricao}{m.lista && <><br /><small className="sub">Dentro da lista: {m.lista.map((x) => `{${x}}`).join(' ')}</small></>}</td>
                    <td className="sub">{exemplos[m.tag]}</td>
                  </tr>
                ))}
              </tbody></table>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

interface Fixo { id: string; nome: string; caminho: string; arquivo: string | null; ordem: number; ativo: boolean; enviado_em: string; enviado_por: string | null }

/** Documentos fixos do empreendimento (memorial, plantas, convenção…): vão como anexos em todo envelope de assinatura. */
function DocumentosFixos() {
  const { avisar, confirmar } = useDialogos();
  const [lista, setLista] = useState<Fixo[] | null>(null);
  const [nome, setNome] = useState('');
  const [ocupado, setOcupado] = useState(false);
  const arq = useRef<HTMLInputElement>(null);

  const carregar = async () => {
    const { data } = await supabase.from('contrato_anexos_fixos').select('*').order('ativo', { ascending: false }).order('ordem').order('enviado_em');
    setLista((data as Fixo[]) ?? []);
  };
  useEffect(() => { carregar(); }, []);

  const enviar = async (f: File) => {
    if (!/\.(pdf|docx)$/i.test(f.name)) { avisar('Envie em PDF (recomendado) ou Word (.docx).', 'erro'); return; }
    if (f.size > 25 * 1024 * 1024) { avisar('Arquivo maior que 25 MB.', 'erro'); return; }
    const titulo = nome.trim() || f.name.replace(/\.[^.]+$/, '');
    setOcupado(true);
    try {
      const ext = /\.docx$/i.test(f.name) ? 'docx' : 'pdf';
      const caminho = `fixos/${crypto.randomUUID()}.${ext}`;
      const { error } = await supabase.storage.from('contratos').upload(caminho, f, { contentType: ext === 'pdf' ? 'application/pdf' : DOCX });
      if (error) throw new Error('Falha ao guardar o arquivo.');
      const ordem = Math.max(0, ...(lista ?? []).filter((x) => x.ativo).map((x) => x.ordem)) + 1;
      const { error: e2 } = await supabase.rpc('salvar_anexo_fixo', { p_nome: titulo, p_caminho: caminho, p_arquivo: f.name, p_ordem: ordem });
      if (e2) throw new Error(e2.message.includes('SEM_PERMISSAO') ? 'Só o administrador cadastra documentos fixos.' : 'Não foi possível registrar o documento.');
      setNome(''); avisar(`“${titulo}” incluído nos próximos envelopes.`);
    } catch (e) { avisar((e as Error).message, 'erro'); }
    finally { setOcupado(false); carregar(); }
  };

  const alterar = async (f: Fixo, mud: { nome?: string; ordem?: number; ativo?: boolean }) => {
    const { error } = await supabase.rpc('alterar_anexo_fixo', { p_id: f.id, p_nome: mud.nome ?? null, p_ordem: mud.ordem ?? null, p_ativo: mud.ativo ?? null });
    if (error) avisar('Não foi possível salvar.', 'erro'); else carregar();
  };
  const trocar = async (i: number, d: -1 | 1) => {
    const ativos = (lista ?? []).filter((x) => x.ativo);
    const a = ativos[i], b = ativos[i + d];
    if (!a || !b) return;
    await alterar(a, { ordem: b.ordem === a.ordem ? a.ordem + d : b.ordem });
    await alterar(b, { ordem: a.ordem });
  };
  const baixar = async (f: Fixo) => {
    const { data } = await supabase.storage.from('contratos').createSignedUrl(f.caminho, 60, { download: f.arquivo || `${f.nome}.pdf` });
    if (data?.signedUrl) window.location.href = data.signedUrl;
  };

  if (!lista) return null;
  const ativos = lista.filter((x) => x.ativo), inativos = lista.filter((x) => !x.ativo);
  return (
    <div className="cartao">
      <div className="cartao-topo">
        <div>
          <h3>Documentos fixos do contrato</h3>
          <p className="sub">Iguais para todas as vendas (memorial descritivo, plantas, minuta da convenção, termo de vistoria…). Entram como anexos no envelope de assinatura, depois do Quadro Resumo, das Normas e da Carta Proposta, na ordem abaixo. Prefira PDF.</p>
        </div>
      </div>
      {ativos.length ? (
        <div className="tabela-rolagem"><table className="tabela">
          <thead><tr><th>Ordem</th><th>Documento</th><th>Arquivo</th><th /></tr></thead>
          <tbody>{ativos.map((f, i) => (
            <tr key={f.id}>
              <td>{i + 1}</td>
              <td><input defaultValue={f.nome} onBlur={(e) => { if (e.target.value.trim() && e.target.value.trim() !== f.nome) alterar(f, { nome: e.target.value }); }} /></td>
              <td><small className="sub">{f.arquivo} · {formatarDataHora(f.enviado_em)}</small></td>
              <td className="ct-acoes">
                <button type="button" className="botao pequeno" disabled={i === 0} onClick={() => trocar(i, -1)}><ArrowUp size={12} /></button>
                <button type="button" className="botao pequeno" disabled={i === ativos.length - 1} onClick={() => trocar(i, 1)}><ArrowDown size={12} /></button>
                <button type="button" className="botao pequeno" onClick={() => baixar(f)}><Download size={12} /> Baixar</button>
                <button type="button" className="botao pequeno" onClick={async () => { if (await confirmar({ titulo: `Tirar “${f.nome}” dos envelopes?`, texto: 'Envelopes já montados não mudam. Dá para reativar depois.', confirmar: 'Desativar' })) alterar(f, { ativo: false }); }}>Desativar</button>
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      ) : <p className="vazio">Nenhum documento fixo ainda.</p>}
      <div className="acoes">
        <input placeholder="Nome do documento (ex.: Memorial Descritivo)" value={nome} onChange={(e) => setNome(e.target.value)} />
        <button type="button" className="botao principal" disabled={ocupado} onClick={() => arq.current?.click()}><FileUp size={16} /> {ocupado ? 'Enviando…' : 'Adicionar documento'}</button>
        <input ref={arq} type="file" hidden accept=".pdf,.docx" onChange={(e) => { const f = e.target.files?.[0]; if (f) enviar(f); e.target.value = ''; }} />
      </div>
      {!!inativos.length && (
        <p className="sub">Desativados: {inativos.map((f, i) => <span key={f.id}>{i > 0 && ', '}{f.nome} <button type="button" className="link" onClick={() => alterar(f, { ativo: true, ordem: ativos.length + 1 })}>reativar</button></span>)}</p>
      )}
    </div>
  );
}
