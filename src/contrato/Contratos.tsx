// Módulo Contratos (administrador e Sec. Vendas): só propostas aprovadas com pasta aprovada.
// Etapas: 1) partes (leitura com IA)  2) unidade (quadro de áreas)  3) pagamento e comissão
// 4) emissão do Quadro Resumo e das Normas em PDF, com validação, cancelamento e download.
import { useCallback, useEffect, useMemo, useState } from 'react';
import { CheckCircle2, Circle, Download, Eye, FileText, FileUp, Plus, Search, Trash2 } from 'lucide-react';
import { supabase, formatarDataHora } from '../dados';
import { useDialogos } from '../ui';
import { ir, conjugeNoContrato, formatarCNPJ, soDigitos, type EstadoCivil, type Perfil } from '../util';
import { fmtData, fmtNum, fmtReal, hojeISO, type Periodicidade } from '../proposta/motor';
import { DadosContrato } from './DadosContrato';
import { EnvelopeAssinatura } from './Envelope';
import { padronizar, type DadosContrato as Dados } from './leitura';
import { CAMPOS_EMPREENDIMENTO, COLUNAS_AREAS, type Areas } from './campos';
import { NOME_DOCUMENTO, type Comissao, type SerieContrato, type TipoDocumento } from './gerador';

interface Linha {
  id: string; codigo: string; pasta_id: string; analisada_em: string | null; resumo: { total?: number } | null;
  unidades: { numero: string } | null;
  pastas: { id: string; codigo: string; status: string; comprador_nome: string; empresa_razao_social: string | null; imobiliarias: { nome: string } | null } | null;
}
interface Registro { pasta_id: string; status: string; dados: Dados; comissao: Comissao[]; pagamento_conferido_em: string | null; pagamento_conferido_por: string | null }
interface Emitido {
  id: string; numero: number; documento: TipoDocumento | 'carta_proposta'; nome: string; caminho: string | null; caminho_docx: string | null; versao: number; validacao: 'aguardando' | 'validado'; assinatura: string;
  gerado_em: string; gerado_por: string | null; validado_por: string | null; cancelado_em: string | null;
  d4sign_uuid?: string | null; enviado_assinatura_em?: string | null; assinado_em?: string | null; caminho_assinado?: string | null;
}

type ComissaoUI = Omit<Comissao, 'valor'> & { valor: string };
const paraTxt = (v: number) => fmtNum(Number(v) || 0, 2);
const doTxt = (t: string) => Number(t.replace(/\./g, '').replace(',', '.')) || 0;
const DOCX = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const ROTULO_ASSINATURA: Record<string, [string, string]> = {
  nao_enviado: ['Não enviado', 'sp-incompleta'], preparado: ['No envelope (prévia)', 'sp-em_analise'], enviado: ['Em assinatura', 'sp-aguardando_analise'],
  assinado: ['Assinado', 'sp-aprovada'], cancelado: ['Cancelado', 'sp-pendente_correcao'],
};
const rotuloAssinatura = (s: string) => ROTULO_ASSINATURA[s] ?? [s, 'sp-incompleta'];
const nomeCliente = (p: Linha['pastas']) => p?.empresa_razao_social || p?.comprador_nome || '—';

export function ListaContratos() {
  const [linhas, setLinhas] = useState<Linha[] | null>(null);
  const [regs, setRegs] = useState<Record<string, Registro>>({});
  const [emitidos, setEmitidos] = useState<Record<string, number>>({});
  const [envelopes, setEnvelopes] = useState<Record<string, string>>({});
  const [busca, setBusca] = useState('');

  useEffect(() => {
    (async () => {
      const { data } = await supabase.from('propostas')
        .select('id, codigo, pasta_id, analisada_em, resumo, unidades(numero), pastas(id, codigo, status, comprador_nome, empresa_razao_social, imobiliarias(nome))')
        .eq('status', 'aprovada').not('pasta_id', 'is', null).order('analisada_em', { ascending: false });
      const ls = ((data as unknown as Linha[]) ?? []).filter((l) => l.pastas?.status === 'aprovada');
      setLinhas(ls);
      const ids = ls.map((l) => l.pasta_id);
      if (!ids.length) return;
      const [{ data: r }, { data: c }, { data: ev }] = await Promise.all([
        supabase.from('dados_contrato').select('pasta_id, status, pagamento_conferido_em').in('pasta_id', ids),
        supabase.from('contratos').select('pasta_id').in('pasta_id', ids).is('cancelado_em', null),
        supabase.from('envelopes').select('pasta_id, status, criado_em').in('pasta_id', ids).neq('status', 'cancelado').order('criado_em'),
      ]);
      // situação do envelope mais recente de cada pasta (preparado, enviado ou assinado)
      setEnvelopes(Object.fromEntries(((ev as { pasta_id: string; status: string }[]) ?? []).map((x) => [x.pasta_id, x.status])));
      setRegs(Object.fromEntries(((r as Registro[]) ?? []).map((x) => [x.pasta_id, x])));
      const n: Record<string, number> = {};
      ((c as { pasta_id: string }[]) ?? []).forEach((x) => { n[x.pasta_id] = (n[x.pasta_id] ?? 0) + 1; });
      setEmitidos(n);
    })();
  }, []);

  const filtradas = useMemo(() => {
    const t = busca.trim().toLowerCase();
    return (linhas ?? []).filter((l) => !t || [l.codigo, l.pastas?.codigo, nomeCliente(l.pastas), l.unidades?.numero, l.pastas?.imobiliarias?.nome]
      .some((x) => (x ?? '').toLowerCase().includes(t)));
  }, [linhas, busca]);

  const etapa = (l: Linha) => {
    const r = regs[l.pasta_id];
    const e = envelopes[l.pasta_id];
    if (e === 'assinado') return ['Contrato assinado', 'sp-aprovada'];
    if (e === 'enviado') return ['Contrato enviado', 'sp-aguardando_analise'];
    if (e === 'preparado') return ['Envelope montado', 'sp-pronta'];
    if (emitidos[l.pasta_id]) return ['Emitido', 'sp-aprovada'];
    if (r?.status === 'conferido' && r.pagamento_conferido_em) return ['Pronto para emitir', 'sp-pronta'];
    if (r) return ['Em conferência', 'sp-em_analise'];
    return ['A iniciar', 'sp-incompleta'];
  };

  return (
    <section className="secao">
      <div className="secao-topo">
        <div>
          <h2>Contratos</h2>
          <p className="sub">Propostas aprovadas com a pasta aprovada. Abra para conferir os dados e emitir o Quadro Resumo e as Normas.</p>
        </div>
      </div>
      <div className="cartao">
        <label className="busca-funil ct-busca"><Search size={16} /><input type="search" placeholder="Buscar por cliente, unidade, pasta, proposta ou imobiliária" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        {!linhas ? <p className="vazio">Carregando…</p> : !filtradas.length ? <p className="vazio">Nenhuma proposta aprovada pronta para contrato.</p> : (
          <div className="tabela-rolagem">
            <table className="tabela">
              <thead><tr><th>Cliente</th><th>Unidade</th><th>Pasta</th><th>Proposta</th><th>Imobiliária</th><th>Valor</th><th>Situação</th></tr></thead>
              <tbody>
                {filtradas.map((l) => {
                  const [rot, cls] = etapa(l);
                  return (
                    <tr key={l.id} tabIndex={0} onClick={() => ir(`/painel/contratos/${l.id}`)} onKeyDown={(e) => e.key === 'Enter' && ir(`/painel/contratos/${l.id}`)}>
                      <td className="celula-titulo"><strong>{nomeCliente(l.pastas)}</strong></td>
                      <td>{l.unidades?.numero ?? '—'}</td>
                      <td className="mono">{l.pastas?.codigo}</td>
                      <td className="mono">{l.codigo}</td>
                      <td>{l.pastas?.imobiliarias?.nome ?? '—'}</td>
                      <td>{l.resumo?.total ? fmtReal(l.resumo.total) : '—'}</td>
                      <td><span className={`selo ${cls}`}>{rot}</span></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </section>
  );
}

interface Proposta {
  id: string; codigo: string; pasta_id: string; status: string; series: SerieContrato[]; parte_sinal?: number | null; resumo: { total?: number; comissao?: number; comissao_imobiliaria?: number; comissao_coordenacao?: number } | null;
  unidades: { numero: string } | null;
}
interface PastaC {
  id: string; codigo: string; status: string; tipo_pessoa: 'pf' | 'pj'; estado_civil: EstadoCivil; regime_bens: string | null; conjuge_participa: boolean;
  comprador_nome: string; empresa_razao_social: string | null; imobiliaria_id: string | null; imobiliarias: { nome: string; cnpj: string | null } | null;
}

export function PaginaContrato({ id }: { id: string; perfil: Perfil }) {
  const { avisar, confirmar } = useDialogos();
  const [prop, setProp] = useState<Proposta | null>(null);
  const [parteSinal, setParteSinal] = useState(0.7);
  const [pasta, setPasta] = useState<PastaC | null>(null);
  const [reg, setReg] = useState<Registro | null>(null);
  const [areas, setAreas] = useState<Areas | null | undefined>(undefined);
  const [emp, setEmp] = useState<Record<string, string>>({});
  const [emit, setEmit] = useState<Emitido[]>([]);
  const [comissao, setComissao] = useState<ComissaoUI[]>([]);
  const [modelos, setModelos] = useState<Partial<Record<TipoDocumento, string>>>({});
  const [escolha, setEscolha] = useState<Record<TipoDocumento, boolean>>({ quadro_resumo: true, normas: true });
  const [ocupado, setOcupado] = useState('');
  const [erro, setErro] = useState('');
  const [comCarta, setComCarta] = useState(true);
  // data do contrato: vale para todos os documentos emitidos (Quadro Resumo, Normas e Carta Proposta)
  const [dataHoje, setDataHoje] = useState(true);
  const [outraData, setOutraData] = useState('');
  const dataContrato = dataHoje || !outraData ? hojeISO() : outraData;

  const carregar = useCallback(async () => {
    const { data: p } = await supabase.from('propostas').select('id, codigo, pasta_id, status, series, resumo, parte_sinal, unidades(numero)').eq('id', id).maybeSingle();
    if (!p || (p as unknown as Proposta).status !== 'aprovada') { setErro('Proposta não encontrada ou não aprovada.'); return; }
    const pr = p as unknown as Proposta;
    setProp(pr);
    const [{ data: pa }, { data: r }, { data: ar }, { data: e }, { data: c }, { data: cm }] = await Promise.all([
      supabase.from('pastas').select('id, codigo, status, tipo_pessoa, estado_civil, regime_bens, conjuge_participa, comprador_nome, empresa_razao_social, imobiliaria_id, imobiliarias(nome, cnpj)').eq('id', pr.pasta_id).maybeSingle(),
      supabase.from('dados_contrato').select('pasta_id, status, dados, comissao, pagamento_conferido_em, pagamento_conferido_por').eq('pasta_id', pr.pasta_id).maybeSingle(),
      supabase.from('unidade_areas').select('*').eq('numero', pr.unidades?.numero ?? '').maybeSingle(),
      supabase.from('empreendimento_contrato').select('dados').maybeSingle(),
      supabase.from('contratos').select('*').eq('pasta_id', pr.pasta_id).order('numero', { ascending: false }),
      supabase.from('comercial').select('coordenacao_comercial, coordenacao_documento, parte_sinal').eq('id', 1).maybeSingle(),
    ]);
    const { data: ms } = await supabase.from('modelos_contrato').select('documento, caminho').eq('ativo', true);
    setModelos(Object.fromEntries(((ms as { documento: TipoDocumento; caminho: string }[]) ?? []).map((m) => [m.documento, m.caminho])));
    const pc = pa as unknown as PastaC;
    setPasta(pc);
    const rg = (r as Registro) ?? null;
    setReg(rg);
    setAreas((ar as Areas) ?? null);
    const empDados = (e?.dados as Record<string, string>) ?? {};
    setEmp(empDados);
    // ativos no topo, na ordem do envelope (Carta Proposta, Intermediação, Quadro Resumo, Normas);
    // cancelados embaixo, do mais recente para o mais antigo
    const ordemDoc: Record<string, number> = { carta_proposta: 0, intermediacao: 1, quadro_resumo: 2, normas: 3 };
    setEmit(((c as Emitido[]) ?? []).sort((x, y) => Number(!!x.cancelado_em) - Number(!!y.cancelado_em)
      || (x.cancelado_em ? 0 : (ordemDoc[x.documento] ?? 9) - (ordemDoc[y.documento] ?? 9)) || y.numero - x.numero));
    // Emissão sugere só o que ainda não foi emitido
    const ativos = new Set(((c as Emitido[]) ?? []).filter((x) => !x.cancelado_em).map((x) => x.documento));
    if (ativos.size) { setEscolha({ quadro_resumo: !ativos.has('quadro_resumo'), normas: !ativos.has('normas') }); setComCarta(!ativos.has('carta_proposta')); }
    // padrão: imobiliária da proposta + coordenação de vendas (paga pelo comprador com o sinal; item 9.3 do Quadro Resumo)
    const coord = cm as { coordenacao_comercial: string | null; coordenacao_documento: string | null; parte_sinal: number | null } | null;
    setParteSinal(Number(pr.parte_sinal ?? coord?.parte_sinal ?? 0.7));
    const forma = 'Conforme contrato de intermediação';
    const vImob = pr.resumo?.comissao_imobiliaria ?? pr.resumo?.comissao;
    const vCoord = pr.resumo?.comissao_coordenacao ?? 0;
    setComissao((rg?.comissao?.length ? rg.comissao : [
      ...(vImob ? [{ nome: pc?.imobiliarias?.nome ?? '', documento: pc?.imobiliarias?.cnpj ?? '', valor: Number(vImob), forma }] : []),
      ...(vCoord ? [{ nome: empDados['coordenacao.razao_social'] || coord?.coordenacao_comercial || 'Coordenação de vendas', documento: empDados['coordenacao.cnpj'] || coord?.coordenacao_documento || '', valor: Number(vCoord), forma }] : []),
    ]).map((c) => ({ ...c, valor: paraTxt(c.valor) })));
  }, [id]);
  useEffect(() => { carregar(); }, [carregar]);

  if (erro) return <section className="secao"><button className="voltar" onClick={() => ir('/painel/contratos')}>‹ Contratos</button><p className="erro">{erro}</p></section>;
  if (!prop || !pasta) return <section className="secao"><p className="vazio">Carregando…</p></section>;

  const pj = pasta.tipo_pessoa === 'pj';
  const temConj = conjugeNoContrato(pasta.estado_civil, pasta.regime_bens, pasta.conjuge_participa, pasta.tipo_pessoa);
  const series = (prop.series ?? []).map((s) => ({ ...s, qtd: Number(s.qtd), valor: Number(s.valor) })).filter((s) => s.qtd > 0 && s.valor > 0);
  const total = series.reduce((t, s) => t + s.qtd * s.valor, 0);
  const difTotal = Math.abs(total - Number(prop.resumo?.total ?? total));
  const camposVazios = CAMPOS_EMPREENDIMENTO.filter((c) => !c.soAssinatura && !emp[c.chave]?.trim());
  const ok = {
    partes: reg?.status === 'conferido',
    unidade: !!areas,
    pagamento: !!reg?.pagamento_conferido_em,
    empreendimento: camposVazios.length === 0,
  };
  const podeEmitir = ok.partes && ok.unidade && ok.pagamento && (escolha.quadro_resumo || escolha.normas || comCarta);

  const salvarComissao = async (conferido: boolean) => {
    if (conferido && comissao.some((c) => !c.nome.trim() || !(doTxt(c.valor) > 0))) { avisar('Preencha nome e valor de cada beneficiário da comissão.', 'erro'); return; }
    const lim = comissao.map((c) => ({ ...c, nome: c.nome.trim(), documento: soDigitos(c.documento), valor: Math.round(doTxt(c.valor) * 100) / 100 }));
    const { error } = await supabase.rpc('conferir_pagamento', { p_pasta: pasta.id, p_comissao: lim, p_conferido: conferido });
    if (error) { avisar('Não foi possível salvar.', 'erro'); return; }
    avisar(conferido ? 'Fluxo de pagamento conferido.' : 'Comissão salva.'); carregar();
  };

  const contexto = () => {
    const d = padronizar(reg?.dados ?? {});
    return {
      campos: emp, tipoPessoa: pasta.tipo_pessoa, empresa: d.empresa ?? null, comprador: d.comprador ?? {}, conjuge: temConj ? d.conjuge ?? null : null,
      representante2: pasta.tipo_pessoa === 'pj' ? d.representante2 ?? null : null,
      unidade: prop.unidades?.numero ?? '', areas: areas ?? null, series, comissao: reg?.comissao ?? [],
      data: dataContrato, referencia: `${pasta.codigo} · ${prop.codigo}`, parteSinal,
    };
  };

  /** Preenche o modelo em Word do documento (o enviado pelo administrador ou o padrão). */
  const wordPreenchido = async (tipo: TipoDocumento, ctx: ReturnType<typeof contexto>) => {
    const { preencherModelo, dadosParaModelo } = await import('./marcadores');
    let modelo: ArrayBuffer;
    if (modelos[tipo]) {
      const { data, error } = await supabase.storage.from('contratos').download(modelos[tipo]!);
      if (error || !data) throw new Error('Não foi possível baixar o modelo do contrato.');
      modelo = await data.arrayBuffer();
    } else modelo = await (await (await import('./modeloBase')).modeloPadrao(tipo)).arrayBuffer();
    return preencherModelo(modelo, dadosParaModelo(ctx));
  };

  const previa = async (tipo: TipoDocumento) => {
    setOcupado(`Montando ${NOME_DOCUMENTO[tipo]}…`);
    try {
      if (!modelos[tipo]) {
        const { gerarDocumento } = await import('./gerador');
        const { pdf } = await gerarDocumento(tipo, contexto());
        window.open(URL.createObjectURL(pdf), '_blank');
      } else {
        const { docx, vazios } = await wordPreenchido(tipo, contexto());
        const a = document.createElement('a'); a.href = URL.createObjectURL(docx); a.download = `Prévia - ${NOME_DOCUMENTO[tipo]}.docx`; a.click();
        if (vazios.length) avisar(`Marcadores sem valor: ${vazios.slice(0, 6).join(', ')}`, 'erro');
      }
    } catch (e) { avisar(`Não foi possível montar o documento. ${(e as Error).message}`, 'erro'); }
    finally { setOcupado(''); }
  };

  const previaCarta = async () => {
    setOcupado('Montando a Carta Proposta…');
    try {
      const { cartaDaProposta, partesDaLeitura } = await import('./cartaContrato');
      window.open(URL.createObjectURL(await cartaDaProposta(prop.id, partesDaLeitura(padronizar(reg?.dados ?? {}), temConj, pj), emp, { data: dataContrato })), '_blank');
    } catch (e) { avisar(`Não foi possível montar a carta. ${(e as Error).message}`, 'erro'); }
    finally { setOcupado(''); }
  };

  const emitir = async () => {
    const tipos = (Object.keys(escolha) as TipoDocumento[]).filter((t) => escolha[t]);
    const nomes = [...tipos.map((t) => NOME_DOCUMENTO[t]), ...(comCarta ? ['Carta Proposta'] : [])];
    if (!dataHoje && !outraData) { avisar('Informe a data do contrato ou escolha "Hoje".', 'erro'); return; }
    if (!(await confirmar({ titulo: `Emitir ${nomes.join(', ').replace(/, ([^,]*)$/, ' e $1')}?`, texto: `Data do contrato: ${fmtData(dataContrato)}${dataHoje ? ' (hoje)' : ''}, em todos os documentos. Eles ficam registrados na pasta, com número, aguardando validação.`, confirmar: 'Emitir' }))) return;
    try {
      const { gerarDocumento } = await import('./gerador');
      for (const t of tipos) {
        setOcupado(`Gerando ${NOME_DOCUMENTO[t]}…`);
        const ctx = contexto();
        // Word sempre a partir do modelo; PDF só quando o modelo é o padrão (com modelo próprio, o PDF sai na D4Sign)
        const [{ docx }, gerado] = await Promise.all([wordPreenchido(t, ctx), modelos[t] ? null : gerarDocumento(t, ctx)]);
        const pdf = gerado?.pdf ?? null;
        const base = `${pasta.id}/${crypto.randomUUID()}`;
        const caminho = pdf ? `${base}.pdf` : null, caminhoDocx = `${base}.docx`;
        const [u1, u2] = await Promise.all([
          pdf ? supabase.storage.from('contratos').upload(caminho!, pdf, { contentType: 'application/pdf' }) : { error: null },
          supabase.storage.from('contratos').upload(caminhoDocx, docx, { contentType: DOCX }),
        ]);
        if (u1.error || u2.error) throw new Error('Falha ao guardar os arquivos.');
        const { error } = await supabase.rpc('registrar_contrato', {
          p_pasta: pasta.id, p_proposta: prop.id, p_documento: t, p_nome: `${NOME_DOCUMENTO[t]} — Unidade ${ctx.unidade}`, p_caminho: caminho, p_caminho_docx: caminhoDocx,
          p_dados: { comprador: ctx.comprador, conjuge: ctx.conjuge, representante2: ctx.representante2, empresa: ctx.empresa, series: ctx.series, comissao: ctx.comissao, areas: ctx.areas, data_contrato: ctx.data, assinaturas: gerado?.assinaturas ?? [] },
        });
        if (error) throw new Error(error.message.includes('NAO_CONFERIDO') ? 'Confira as partes e o pagamento antes de emitir.' : 'Não foi possível registrar o documento.');
      }
      if (comCarta) {
        setOcupado('Gerando a Carta Proposta…');
        const { cartaDaProposta, partesDaLeitura } = await import('./cartaContrato');
        const partes = partesDaLeitura(padronizar(reg?.dados ?? {}), temConj, pj);
        let posCarta: unknown[] = [];
        const [pdf, docx] = await Promise.all([
          cartaDaProposta(prop.id, partes, emp, { data: dataContrato, aoAssinaturas: (p) => { posCarta = p; } }),
          cartaDaProposta(prop.id, partes, emp, { data: dataContrato, formato: 'docx' }),
        ]);
        const base = `${pasta.id}/${crypto.randomUUID()}`;
        const caminho = `${base}.pdf`, caminhoDocx = `${base}.docx`;
        const [e1, e2] = await Promise.all([
          supabase.storage.from('contratos').upload(caminho, pdf, { contentType: 'application/pdf' }),
          supabase.storage.from('contratos').upload(caminhoDocx, docx, { contentType: DOCX }),
        ]);
        if (e1.error || e2.error) throw new Error('Falha ao guardar a carta proposta.');
        const { error } = await supabase.rpc('registrar_contrato', {
          p_pasta: pasta.id, p_proposta: prop.id, p_documento: 'carta_proposta', p_nome: `Carta Proposta ${prop.codigo} — Unidade ${prop.unidades?.numero ?? ''}`,
          p_caminho: caminho, p_caminho_docx: caminhoDocx, p_dados: { proposta: prop.codigo, data_contrato: dataContrato, assinaturas: posCarta },
        });
        if (error) throw new Error('Não foi possível registrar a carta proposta.');
      }
      avisar('Documentos emitidos. Confira e valide.');
    } catch (e) { avisar((e as Error).message, 'erro'); }
    finally { setOcupado(''); carregar(); }
  };

  const baixar = async (c: Emitido, word = false) => {
    const caminho = word ? c.caminho_docx : c.caminho;
    if (!caminho) return;
    const { data } = await supabase.storage.from('contratos').createSignedUrl(caminho, 60, { download: `${c.numero} - ${c.nome} (v${c.versao}).${word ? 'docx' : 'pdf'}` });
    if (data?.signedUrl) window.location.href = data.signedUrl; else avisar('Não foi possível baixar.', 'erro');
  };

  /** Ajuste: Word (.docx) e/ou PDF escolhidos juntos viram a próxima versão. */
  const enviarAjuste = async (c: Emitido, arquivos: FileList) => {
    const docx = [...arquivos].find((f) => /\.docx$/i.test(f.name));
    const pdf = [...arquivos].find((f) => /\.pdf$/i.test(f.name));
    if (!docx && !pdf) { avisar('Envie o arquivo em Word (.docx) ou PDF.', 'erro'); return; }
    if ([docx, pdf].some((f) => f && f.size > 25 * 1024 * 1024)) { avisar('Arquivo maior que 25 MB.', 'erro'); return; }
    if (!(await confirmar({ titulo: `Enviar versão ${c.versao + 1} do nº ${c.numero}?`, texto: `${[docx && 'Word', pdf && 'PDF'].filter(Boolean).join(' e ')} ajustado(s). A validação volta para pendente.${docx && !pdf ? ' O PDF desta versão será gerado pela D4Sign no envio para assinatura.' : ''}`, confirmar: 'Enviar versão' }))) return;
    setOcupado(`Enviando a versão ${c.versao + 1}…`);
    try {
      const base = `${pasta.id}/${crypto.randomUUID()}`;
      const sobe = async (f: File | undefined, ext: string, tipo: string) => {
        if (!f) return null;
        const { error } = await supabase.storage.from('contratos').upload(`${base}.${ext}`, f, { contentType: tipo });
        if (error) throw new Error('Falha ao guardar o arquivo.');
        return `${base}.${ext}`;
      };
      const [cd, cp] = await Promise.all([sobe(docx, 'docx', DOCX), sobe(pdf, 'pdf', 'application/pdf')]);
      const { error } = await supabase.rpc('enviar_versao_contrato', { p_id: c.id, p_caminho_docx: cd, p_caminho_pdf: cp });
      if (error) throw new Error(/JA_ENVIADO|EM_ENVELOPE/.test(error.message) ? 'Este documento está num envelope de assinatura. Descarte o envelope para ajustar.' : 'Não foi possível registrar a versão.');
      avisar(`Versão ${c.versao + 1} registrada. Confira e valide.`);
    } catch (e) { avisar((e as Error).message, 'erro'); }
    finally { setOcupado(''); carregar(); }
  };
  const acao = async (c: Emitido, rpc: 'validar_contrato' | 'cancelar_contrato') => {
    if (rpc === 'cancelar_contrato' && !(await confirmar({ titulo: `Cancelar o documento nº ${c.numero}?`, texto: 'Ele continua no histórico, marcado como cancelado.', confirmar: 'Cancelar documento', perigo: true }))) return;
    const { error } = await supabase.rpc(rpc, { p_id: c.id });
    if (error) avisar(/EM_ENVELOPE|JA_ENVIADO/.test(error.message) ? 'Este documento está num envelope de assinatura.' : 'Não foi possível concluir.', 'erro'); else carregar();
  };

  const Etapa = ({ feito, titulo }: { feito: boolean; titulo: string }) => (
    <span className={`ct-etapa ${feito ? 'feito' : ''}`}>{feito ? <CheckCircle2 size={16} /> : <Circle size={16} />} {titulo}</span>
  );

  return (
    <section className="secao contrato">
      <button className="voltar" onClick={() => ir('/painel/contratos')}>‹ Contratos</button>
      <div className="secao-topo">
        <div>
          <h2>{pasta.empresa_razao_social || pasta.comprador_nome}</h2>
          <p className="sub">Unidade <strong>{prop.unidades?.numero}</strong> · pasta <a href={`/painel/pastas/${pasta.id}`} onClick={(e) => { e.preventDefault(); ir(`/painel/pastas/${pasta.id}`); }} className="mono">{pasta.codigo}</a>
            {' '}· proposta <a href={`/painel/propostas/${prop.id}`} onClick={(e) => { e.preventDefault(); ir(`/painel/propostas/${prop.id}`); }} className="mono">{prop.codigo}</a>
            {pasta.imobiliarias?.nome && <> · {pasta.imobiliarias.nome}</>}{pj && <> · Pessoa jurídica</>}</p>
        </div>
      </div>
      <div className="ct-etapas">
        <Etapa feito={ok.partes} titulo="1. Partes" /><Etapa feito={ok.unidade} titulo="2. Unidade" />
        <Etapa feito={ok.pagamento} titulo="3. Pagamento" /><Etapa feito={emit.some((c) => !c.cancelado_em)} titulo="4. Emissão" />
      </div>

      <DadosContrato pastaId={pasta.id} temConjuge={temConj} pj={pj} aoMudar={carregar} />

      <div className="cartao">
        <div className="cartao-topo"><h3>Unidade e quadro de áreas</h3>{areas && <span className="selo sp-aprovada">Encontrada</span>}</div>
        {areas === undefined ? <p className="vazio">Carregando…</p> : !areas
          ? <p className="erro">A unidade {prop.unidades?.numero} não está no quadro de áreas. O administrador importa a planilha em Empreendimento → Quadro de áreas.</p>
          : (
            <dl className="ct-areas">
              {COLUNAS_AREAS.filter(([k]) => k !== 'numero').map(([k, r]) => (
                <div key={k}><dt>{r}</dt><dd>{areas[k] == null || areas[k] === '' ? '—' : k === 'fracao_ideal' ? `${fmtNum(Number(areas[k]) * 100, 5)}%` : typeof areas[k] === 'number' || /^[\d.]+$/.test(String(areas[k])) ? fmtNum(Number(areas[k]), 4) : String(areas[k])}</dd></div>
              ))}
            </dl>
          )}
      </div>

      <div className="cartao">
        <div className="cartao-topo">
          <div>
            <h3>Fluxo de pagamento e comissão</h3>
            <p className="sub">{reg?.pagamento_conferido_em ? <>Conferido por {reg.pagamento_conferido_por} em {formatarDataHora(reg.pagamento_conferido_em)}.</> : 'Confira as séries da proposta aprovada e os beneficiários da comissão.'}</p>
          </div>
          {reg?.pagamento_conferido_em && <span className="selo sp-aprovada">Conferido</span>}
        </div>
        <div className="tabela-rolagem">
          <table className="tabela ct-fluxo">
            <thead><tr><th>Série</th><th>Periodicidade</th><th>Quant.</th><th>Valor unitário</th><th>Valor total</th><th>%</th><th>1º vencimento</th><th>Correção</th></tr></thead>
            <tbody>
              {series.map((s, i) => (
                <tr key={i}><td>{i + 1}</td><td>{s.periodicidade === 'Unica' ? 'Única' : s.periodicidade as Periodicidade}</td><td>{s.qtd}</td><td>{fmtReal(s.valor)}</td>
                  <td>{fmtReal(s.qtd * s.valor)}</td><td>{fmtNum((s.qtd * s.valor * 100) / total, 2)}%</td><td>{fmtData(s.vencimento)}</td><td>{s.periodicidade === 'Sinal' ? 'Fixa' : 'Reajustável'}</td></tr>
              ))}
              <tr className="total"><td colSpan={4}>Total</td><td>{fmtReal(total)}</td><td>100%</td><td colSpan={2} /></tr>
            </tbody>
          </table>
        </div>
        {difTotal > 0.05 && <p className="erro">A soma das séries ({fmtReal(total)}) é diferente do total da proposta ({fmtReal(Number(prop.resumo?.total))}). Confira a proposta.</p>}

        <h4 className="ct-sub">Comissão (item 9.3 do Quadro Resumo)</h4>
        {comissao.map((c, i) => (
          <div key={i} className="ct-comissao">
            <label>Beneficiário<input value={c.nome} onChange={(e) => setComissao(comissao.map((x, j) => (j === i ? { ...x, nome: e.target.value } : x)))} /></label>
            <label>CPF / CNPJ<input value={soDigitos(c.documento).length === 14 ? formatarCNPJ(c.documento) : c.documento} onChange={(e) => setComissao(comissao.map((x, j) => (j === i ? { ...x, documento: e.target.value } : x)))} /></label>
            <label>Valor (R$)<input inputMode="decimal" value={c.valor} onChange={(e) => setComissao(comissao.map((x, j) => (j === i ? { ...x, valor: e.target.value } : x)))} onBlur={() => setComissao(comissao.map((x, j) => (j === i ? { ...x, valor: paraTxt(doTxt(x.valor)) } : x)))} /></label>
            <label>Forma<input value={c.forma} onChange={(e) => setComissao(comissao.map((x, j) => (j === i ? { ...x, forma: e.target.value } : x)))} /></label>
            <button type="button" className="botao pequeno" title="Remover" onClick={() => setComissao(comissao.filter((_, j) => j !== i))}><Trash2 size={16} /></button>
          </div>
        ))}
        <div className="acoes">
          <button type="button" className="botao" onClick={() => setComissao([...comissao, { nome: '', documento: '', valor: '0,00', forma: 'TED / PIX' }])}><Plus size={16} /> Beneficiário</button>
          <span className="sub ct-total-com">Total da comissão: {fmtReal(comissao.reduce((t, c) => t + doTxt(c.valor), 0))}</span>
          {reg?.pagamento_conferido_em
            ? <button type="button" className="botao" onClick={() => salvarComissao(false)}>Reabrir conferência</button>
            : <button type="button" className="botao" onClick={() => salvarComissao(false)}>Salvar comissão</button>}
          <button type="button" className="botao principal" onClick={() => salvarComissao(true)} disabled={difTotal > 0.05}><CheckCircle2 size={16} /> Marcar fluxo como conferido</button>
        </div>
      </div>

      <div className="cartao">
        <div className="cartao-topo"><h3>Emissão</h3></div>
        <ul className="ct-pendencias">
          {!ok.partes && <li>Conferir as partes do contrato (leitura com IA → Marcar como conferido).</li>}
          {!ok.unidade && <li>Unidade sem quadro de áreas.</li>}
          {!ok.pagamento && <li>Conferir o fluxo de pagamento e a comissão.</li>}
          {!ok.empreendimento && <li>Faltam {camposVazios.length} dado(s) em Empreendimento → Dados para contrato ({camposVazios.map((c) => c.rotulo).join('; ')}). Dá para emitir assim: esses pontos saem em branco (____) no documento, para completar no Word ou emitir de novo depois de preencher.</li>}
        </ul>
        <div className="ct-escolha">
          {(Object.keys(NOME_DOCUMENTO) as TipoDocumento[]).map((t) => (
            <label key={t} className="ct-doc">
              <input type="checkbox" checked={escolha[t]} onChange={(e) => setEscolha({ ...escolha, [t]: e.target.checked })} />
              <FileText size={16} /> {NOME_DOCUMENTO[t]} <small className="sub">{modelos[t] ? 'modelo do empreendimento (Word)' : 'modelo padrão'}</small>
              <button type="button" className="botao pequeno" disabled={!!ocupado} onClick={() => previa(t)}><Eye size={14} /> {modelos[t] ? 'Prévia em Word' : 'Pré-visualizar'}</button>
            </label>
          ))}
          <label className="ct-doc">
            <input type="checkbox" checked={comCarta} onChange={(e) => setComCarta(e.target.checked)} />
            <FileText size={16} /> Carta Proposta <small className="sub">modelo da proposta, com os dados conferidos (PDF e Word)</small>
            <button type="button" className="botao pequeno" disabled={!!ocupado} onClick={previaCarta}><Eye size={14} /> Pré-visualizar</button>
          </label>
        </div>
        <div className="ct-data">
          <span>Data do contrato</span>
          <label><input type="radio" name="data-contrato" checked={dataHoje} onChange={() => setDataHoje(true)} /> Hoje ({fmtData(hojeISO())})</label>
          <label><input type="radio" name="data-contrato" checked={!dataHoje} onChange={() => setDataHoje(false)} /> Outra data</label>
          {!dataHoje && <input type="date" value={outraData} onChange={(e) => setOutraData(e.target.value)} aria-label="Data do contrato" />}
          <small className="sub">Sai no local e data de todos os documentos.</small>
        </div>
        <div className="acoes">
          {ocupado && <span className="sub">{ocupado}</span>}
          <button type="button" className="botao principal" disabled={!podeEmitir || !!ocupado} onClick={emitir}>Emitir documentos</button>
        </div>

        {emit.length > 0 && (
          <div className="tabela-rolagem">
            <table className="tabela ct-emitidos">
              <thead><tr><th>Número</th><th>Documento</th><th>Versão</th><th>Assinatura</th><th>Validação</th><th /></tr></thead>
              <tbody>
                {emit.map((c) => (
                  <tr key={c.id} className={c.cancelado_em && c.assinatura !== 'cancelado' ? 'cancelado' : ''}>
                    <td className="mono">{c.numero}</td>
                    <td><strong>{c.nome}</strong><br /><small className="sub">Gerado em {formatarDataHora(c.gerado_em)} por {c.gerado_por}</small></td>
                    <td>v{c.versao}{c.versao > 1 && <><br /><small className="sub">{c.caminho ? 'ajustada' : 'Word ajustado'}</small></>}</td>
                    <td>{c.cancelado_em && c.assinatura === 'nao_enviado' ? <span className="selo sp-pendente_correcao">Cancelado</span> : <span className={`selo ${rotuloAssinatura(c.assinatura)[1]}`}>{rotuloAssinatura(c.assinatura)[0]}</span>}</td>
                    <td>{c.cancelado_em ? '—' : c.validacao === 'validado'
                      ? <span className="selo sp-aprovada" title={`por ${c.validado_por}`}>Validado</span>
                      : <button type="button" className="botao" onClick={() => acao(c, 'validar_contrato')}>Validar</button>}</td>
                    <td className="ct-acoes">
                      {c.caminho && <button type="button" className="botao pequeno" title="Baixar PDF" onClick={() => baixar(c)}><Download size={14} /> PDF</button>}
                      {c.caminho_docx && <button type="button" className="botao pequeno" title="Baixar Word editável" onClick={() => baixar(c, true)}><Download size={14} /> Word</button>}
                      {!c.cancelado_em && c.assinatura === 'nao_enviado' && (
                        <label className="botao pequeno" title="Enviar o Word (e, se quiser, o PDF) ajustado">
                          <FileUp size={14} /> Enviar ajuste
                          <input type="file" hidden multiple accept=".docx,.pdf" disabled={!!ocupado} onChange={(e) => { if (e.target.files?.length) enviarAjuste(c, e.target.files); e.target.value = ''; }} />
                        </label>
                      )}
                      {!c.cancelado_em && c.assinatura === 'nao_enviado' && <button type="button" className="botao pequeno" onClick={() => acao(c, 'cancelar_contrato')}>Cancelar</button>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="sub">Para ajustar a formatação: baixe o Word, edite e use “Enviar ajuste” (só o Word, ou o Word e o PDF juntos). Com todos validados, monte o envelope abaixo: ele junta a versão mais recente de cada documento e os documentos fixos.</p>
          </div>
        )}
      </div>

      {emit.some((c) => !c.cancelado_em) && (
        <EnvelopeAssinatura pastaId={pasta.id} documentos={emit} dados={padronizar(reg?.dados ?? {})} temConjuge={temConj} pj={pj} emp={emp} imobiliariaId={pasta.imobiliaria_id} aoMudar={carregar} />
      )}
    </section>
  );
}
