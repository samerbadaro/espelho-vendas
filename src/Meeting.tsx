import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react';
import { CalendarDays, Check, Copy, Download, ExternalLink, MapPin, Plus, Search, Trash2, Users } from 'lucide-react';
import { supabase } from './dados';
import { formatarTelefone, type Perfil } from './util';
import { Logo, useDialogos, useMarca } from './ui';
import { Recepcao } from './Recepcao';

// =====================================================================
// Meeting: inscrição pública (como o Sympla) + confirmação de presença.
//   /meeting/<endereço>   página pública de inscrição (sem login)
//   /painel/meeting       gestão: meetings, inscritos e recepção
// =====================================================================

const ERROS: Record<string, string> = {
  EMAIL_JA_INSCRITO: 'Este e-mail já está inscrito neste meeting.',
  TELEFONE_JA_INSCRITO: 'Este celular já está inscrito neste meeting.',
  INSCRICOES_ENCERRADAS: 'As inscrições deste meeting estão encerradas.',
  VAGAS_ESGOTADAS: 'As vagas deste meeting estão esgotadas.',
  NOME_COMPLETO_OBRIGATORIO: 'Informe o nome completo (nome e sobrenome).',
  EMAIL_INVALIDO: 'Informe um e-mail válido.',
  TELEFONE_INVALIDO: 'Informe o celular com DDD.',
  MEETING_NAO_ENCONTRADO: 'Meeting não encontrado.',
  ENDERECO_EM_USO: 'Este endereço já é usado por outro meeting.',
  ENDERECO_INVALIDO: 'Endereço: use só letras minúsculas, números e hífen (mínimo 3).',
  NOME_OBRIGATORIO: 'Informe o nome do meeting.',
  SEM_PERMISSAO: 'Sem permissão para esta ação.',
};
const erroMeeting = (msg: string) => ERROS[Object.keys(ERROS).find((k) => msg.includes(k)) ?? ''] ?? 'Não foi possível concluir. Tente de novo.';
const dataLonga = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR', { weekday: 'long', day: '2-digit', month: 'long', hour: '2-digit', minute: '2-digit' }) : '');
const slugDe = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60);

/** Arquivo de calendário (.ics) para o participante salvar o meeting. */
function baixarCalendario(nome: string, inicio: string | null, local: string | null) {
  if (!inicio) return;
  const d = new Date(inicio);
  const fim = new Date(d.getTime() + 2 * 3600_000);
  const f = (x: Date) => x.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const ics = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Meeting//PT-BR', 'BEGIN:VEVENT', `UID:${f(d)}-${Math.random().toString(36).slice(2)}`,
    `DTSTAMP:${f(new Date())}`, `DTSTART:${f(d)}`, `DTEND:${f(fim)}`, `SUMMARY:${nome}`, local ? `LOCATION:${local}` : '', 'END:VEVENT', 'END:VCALENDAR']
    .filter(Boolean).join('\r\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([ics], { type: 'text/calendar' }));
  a.download = `${slugDe(nome)}.ics`; a.click(); URL.revokeObjectURL(a.href);
}

// ---------------------------------------------------------------------
// Página pública de inscrição
// ---------------------------------------------------------------------
interface MeetingPub { nome: string; data_hora: string | null; local: string | null; descricao: string | null; abertas: boolean; motivo: 'encerradas' | 'esgotadas' | null; vagas_restantes: number | null }

export function MeetingPublico({ slug }: { slug: string }) {
  const { marca } = useMarca();
  const [m, setM] = useState<MeetingPub | null | undefined>(undefined);
  const [nome, setNome] = useState('');
  const [email, setEmail] = useState('');
  const [tel, setTel] = useState('');
  const [imob, setImob] = useState('');
  const [site, setSite] = useState(''); // campo invisível contra robôs
  const [erro, setErro] = useState('');
  const [enviando, setEnviando] = useState(false);
  const [feito, setFeito] = useState<{ codigo: string; nome: string } | null>(null);

  useEffect(() => {
    supabase.rpc('meeting_publico', { p_slug: slug }).then(({ data }) => setM((data as MeetingPub) ?? null));
  }, [slug]);
  useEffect(() => { if (m?.nome) document.title = `${m.nome} · Inscrição`; }, [m?.nome]);

  const enviar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (site) return;
    if (nome.trim().split(/\s+/).length < 2) { setErro(ERROS.NOME_COMPLETO_OBRIGATORIO); return; }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())) { setErro(ERROS.EMAIL_INVALIDO); return; }
    if (tel.length < 10) { setErro(ERROS.TELEFONE_INVALIDO); return; }
    setEnviando(true);
    const { data, error } = await supabase.rpc('inscrever_meeting', { p_slug: slug, p_nome: nome, p_email: email, p_telefone: tel, p_imobiliaria: imob || null });
    setEnviando(false);
    if (error) { setErro(erroMeeting(error.message)); return; }
    setFeito(data as { codigo: string; nome: string });
  };

  if (m === undefined) return <div className="meeting-pub"><p className="vazio">Carregando…</p></div>;
  if (m === null) return <div className="meeting-pub"><div className="meeting-cartao"><h1>Meeting não encontrado</h1><p className="sub">Confira o link recebido.</p></div></div>;

  return (
    <div className="meeting-pub">
      <header className="meeting-topo">
        <Logo escuro className="meeting-logo" />
        <h1>{m.nome}</h1>
        <div className="meeting-info">
          {m.data_hora && <span><CalendarDays size={16} /> {dataLonga(m.data_hora)}</span>}
          {m.local && <span><MapPin size={16} /> {m.local}</span>}
        </div>
      </header>

      <main className="meeting-cartao">
        {feito ? (
          <div className="meeting-ok">
            <span className="meeting-check"><Check size={30} /></span>
            <h2>Inscrição confirmada</h2>
            <p>{feito.nome.split(' ')[0]}, sua presença no <strong>{m.nome}</strong> está registrada.</p>
            <div className="meeting-codigo"><span>Código da inscrição</span><strong>{feito.codigo}</strong></div>
            <p className="sub">Na recepção, basta informar seu nome.</p>
            {m.data_hora && <button className="botao" onClick={() => baixarCalendario(m.nome, m.data_hora, m.local)}><CalendarDays size={16} /> Salvar na agenda</button>}
          </div>
        ) : (
          <>
            {m.descricao && <p className="meeting-desc">{m.descricao}</p>}
            {!m.abertas ? (
              <div className="meeting-fechado">{m.motivo === 'esgotadas' ? 'As vagas deste meeting estão esgotadas.' : 'As inscrições deste meeting estão encerradas.'}</div>
            ) : (
              <form onSubmit={enviar} className="meeting-form" noValidate>
                <h2>Faça sua inscrição</h2>
                {m.vagas_restantes != null && m.vagas_restantes <= 30 && <p className="meeting-vagas">Restam {m.vagas_restantes} {m.vagas_restantes === 1 ? 'vaga' : 'vagas'}</p>}
                <label>Nome completo<input value={nome} onChange={(e) => setNome(e.target.value)} autoComplete="name" maxLength={120} required /></label>
                <label>E-mail<input type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" inputMode="email" maxLength={120} required /></label>
                <label>Celular (WhatsApp)<input value={formatarTelefone(tel)} onChange={(e) => setTel(e.target.value.replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, '').slice(0, 11))} autoComplete="tel" inputMode="tel" placeholder="(64) 99999-9999" required /></label>
                <label><span>Imobiliária <small>(opcional)</small></span><input value={imob} onChange={(e) => setImob(e.target.value)} maxLength={80} /></label>
                <input className="meeting-mel" tabIndex={-1} autoComplete="off" value={site} onChange={(e) => setSite(e.target.value)} aria-hidden="true" />
                {erro && <p className="erro" role="alert">{erro}</p>}
                <button className="botao principal grande" disabled={enviando}>{enviando ? 'Enviando…' : 'Confirmar inscrição'}</button>
                <p className="dica">Cada e-mail e cada celular podem ser usados uma única vez neste meeting.</p>
              </form>
            )}
          </>
        )}
      </main>
      <footer className="meeting-rodape">{marca.nome_empreendimento}</footer>
    </div>
  );
}

// ---------------------------------------------------------------------
// Painel: meetings, inscrições e confirmação de presença
// ---------------------------------------------------------------------
interface Evento {
  id: string; nome: string; slug: string; data_hora: string | null; local: string | null; descricao: string | null;
  inscricoes_abertas: boolean; vagas: number | null; encerra_em: string | null;
}
interface Inscrito {
  id: string; nome: string; email: string | null; telefone: string | null; imobiliaria: string | null; origem: string;
  codigo: string | null; inscrito_em: string | null; presente: boolean; chegada_em: string | null; criado_em: string;
}

const paraLocal = (iso: string | null) => {
  if (!iso) return '';
  const d = new Date(iso); const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
};

export function MeetingPainel({ perfil: _perfil }: { perfil: Perfil }) {
  const [eventos, setEventos] = useState<Evento[] | null>(null);
  const [id, setId] = useState<string>(() => new URLSearchParams(window.location.search).get('m') ?? '');
  const [aba, setAba] = useState<'inscricoes' | 'presenca'>(() => (new URLSearchParams(window.location.search).get('aba') === 'presenca' || window.location.pathname.endsWith('/recepcao') ? 'presenca' : 'inscricoes'));
  const [editando, setEditando] = useState<Evento | 'novo' | null>(null);

  const carregar = useCallback(async (selecionar?: string) => {
    const { data } = await supabase.from('recepcao_eventos').select('id, nome, slug, data_hora, local, descricao, inscricoes_abertas, vagas, encerra_em').order('data_hora', { ascending: false, nullsFirst: false });
    const l = (data as Evento[]) ?? [];
    setEventos(l);
    setId((atual) => selecionar ?? (l.find((e) => e.id === atual) ? atual : l[0]?.id ?? ''));
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const mudar = (novo: Partial<{ id: string; aba: 'inscricoes' | 'presenca' }>) => {
    if (novo.id !== undefined) setId(novo.id);
    if (novo.aba) setAba(novo.aba);
    const url = new URL(window.location.href);
    url.pathname = '/painel/meeting';
    url.searchParams.set('m', novo.id ?? id);
    url.searchParams.set('aba', novo.aba ?? aba);
    window.history.replaceState(null, '', url);
  };

  if (eventos == null) return <section className="secao"><p className="vazio">Carregando…</p></section>;
  const ev = eventos.find((e) => e.id === id);

  return (
    <div className="meeting-painel">
      <section className="secao">
        <div className="secao-topo">
          <div>
            <h2>Meeting</h2>
            {eventos.length > 0 ? (
              <select className="seletor-evento" value={id} onChange={(e) => mudar({ id: e.target.value })} aria-label="Meeting">
                {eventos.map((e) => <option key={e.id} value={e.id}>{e.nome}{e.data_hora ? ` · ${new Date(e.data_hora).toLocaleDateString('pt-BR')}` : ''}</option>)}
              </select>
            ) : <p className="sub">Crie o primeiro meeting para abrir as inscrições.</p>}
          </div>
          <div className="botoes-linha">
            {ev && <button className="botao" onClick={() => setEditando(ev)}>Editar meeting</button>}
            <button className="botao principal" onClick={() => setEditando('novo')}><Plus size={16} /> Novo meeting</button>
          </div>
        </div>
        {ev && (
          <div className="abas" role="tablist">
            <button role="tab" aria-selected={aba === 'inscricoes'} className={aba === 'inscricoes' ? 'ativa' : ''} onClick={() => mudar({ aba: 'inscricoes' })}>Inscrições</button>
            <button role="tab" aria-selected={aba === 'presenca'} className={aba === 'presenca' ? 'ativa' : ''} onClick={() => mudar({ aba: 'presenca' })}>Confirmação de presença</button>
          </div>
        )}
        {ev && aba === 'inscricoes' && <Inscricoes ev={ev} />}
      </section>
      {ev && aba === 'presenca' && <Recepcao key={ev.id} eventoFixo={ev.id} />}
      {editando && <EditarMeeting ev={editando === 'novo' ? null : editando} aoFechar={() => setEditando(null)}
        aoSalvar={(novo) => { setEditando(null); carregar(novo.id); mudar({ id: novo.id, aba: 'inscricoes' }); }} />}
    </div>
  );
}

function Inscricoes({ ev }: { ev: Evento }) {
  const { avisar, confirmar } = useDialogos();
  const [lista, setLista] = useState<Inscrito[] | null>(null);
  const [busca, setBusca] = useState('');
  const link = `${window.location.origin}/meeting/${ev.slug}`;

  const carregar = useCallback(async () => {
    const { data, error } = await supabase.from('recepcao_participantes')
      .select('id, nome, email, telefone, imobiliaria, origem, codigo, inscrito_em, presente, chegada_em, criado_em')
      .eq('evento_id', ev.id).order('criado_em', { ascending: false }).limit(5000);
    if (error) avisar('Não foi possível carregar os inscritos.', 'erro'); else setLista((data as Inscrito[]) ?? []);
  }, [ev.id, avisar]);
  useEffect(() => { carregar(); }, [carregar]);
  useEffect(() => {
    const canal = supabase.channel(`inscricoes-${ev.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'recepcao_participantes', filter: `evento_id=eq.${ev.id}` }, () => carregar())
      .subscribe();
    return () => { supabase.removeChannel(canal); };
  }, [ev.id, carregar]);

  const termo = busca.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  const filtrados = useMemo(() => (lista ?? []).filter((p) => !termo || `${p.nome} ${p.email ?? ''} ${p.telefone ?? ''} ${p.imobiliaria ?? ''} ${p.codigo ?? ''}`
    .normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().includes(termo)), [lista, termo]);
  const total = lista?.length ?? 0;
  const inscritosLink = (lista ?? []).filter((p) => p.origem === 'inscricao').length;
  const presentes = (lista ?? []).filter((p) => p.presente).length;

  const copiar = async () => { try { await navigator.clipboard.writeText(link); avisar('Link copiado.'); } catch { avisar(link); } };
  const exportar = () => {
    const linhas = (lista ?? []).slice().sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR')).map((p) => [
      p.nome, p.email ?? '', formatarTelefone(p.telefone), p.imobiliaria ?? '', p.codigo ?? '',
      p.origem === 'inscricao' ? 'Inscrição' : p.origem === 'na_hora' ? 'Incluído na hora' : 'Lista',
      p.inscrito_em ? new Date(p.inscrito_em).toLocaleString('pt-BR') : '', p.presente ? 'Sim' : 'Não',
      p.chegada_em ? new Date(p.chegada_em).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : '',
    ]);
    const csv = [['Nome', 'E-mail', 'Celular', 'Imobiliária', 'Código', 'Origem', 'Inscrito em', 'Presente', 'Chegada'], ...linhas]
      .map((l) => l.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(';')).join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }));
    a.download = `inscritos-${ev.slug}.csv`; a.click(); URL.revokeObjectURL(a.href);
  };
  const remover = async (p: Inscrito) => {
    if (!(await confirmar({ titulo: 'Remover inscrição?', texto: `${p.nome}. O e-mail e o celular ficam livres para uma nova inscrição.`, confirmar: 'Remover' }))) return;
    const { error } = await supabase.rpc('remover_inscricao', { p_id: p.id });
    if (error) avisar(erroMeeting(error.message), 'erro'); else carregar();
  };
  const vagasRest = ev.vagas != null ? Math.max(0, ev.vagas - total) : null;
  const encerrado = ev.encerra_em && new Date(ev.encerra_em) <= new Date();

  return (
    <>
      <div className="cartao meeting-resumo">
        <div className="meeting-link">
          <span className={`selo ${ev.inscricoes_abertas && !encerrado ? 'spr-aprovada' : 'spr-cancelada'}`}>{ev.inscricoes_abertas && !encerrado ? 'Inscrições abertas' : 'Inscrições fechadas'}</span>
          <code>{link}</code>
          <button className="botao pequeno" onClick={copiar}><Copy size={14} /> Copiar link</button>
          <a className="botao pequeno" href={link} target="_blank" rel="noreferrer"><ExternalLink size={14} /> Abrir página</a>
        </div>
        <div className="kpis">
          <div className="kpi"><span className="kpi-valor">{total}</span><span className="kpi-rotulo">Na lista</span><span className="kpi-detalhe">{inscritosLink} pelo link de inscrição</span></div>
          <div className="kpi"><span className="kpi-valor">{vagasRest ?? '—'}</span><span className="kpi-rotulo">Vagas restantes</span><span className="kpi-detalhe">{ev.vagas ? `de ${ev.vagas}` : 'Sem limite'}</span></div>
          <div className="kpi s-disponivel"><span className="kpi-valor">{presentes}</span><span className="kpi-rotulo">Presentes</span></div>
          <div className="kpi"><span className="kpi-valor kpi-texto">{ev.data_hora ? new Date(ev.data_hora).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' }) : '—'}</span><span className="kpi-rotulo">{ev.data_hora ? new Date(ev.data_hora).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : 'Data a definir'}</span><span className="kpi-detalhe">{ev.local ?? ''}</span></div>
        </div>
      </div>

      <div className="cartao">
        <div className="cartao-topo">
          <h3><Users size={18} /> Inscritos ({filtrados.length})</h3>
          <div className="botoes-linha">
            <label className="busca-simples"><Search size={16} /><input value={busca} onChange={(e) => setBusca(e.target.value)} placeholder="Buscar nome, e-mail, celular, código…" /></label>
            <button className="botao" onClick={exportar} disabled={!total}><Download size={16} /> Exportar</button>
          </div>
        </div>
        {lista == null ? <p className="vazio">Carregando…</p> : filtrados.length === 0 ? <p className="vazio">{total ? 'Ninguém com essa busca.' : 'Nenhuma inscrição ainda. Divulgue o link acima.'}</p> : (
          <div className="tabela-rolagem">
            <table className="tabela">
              <thead><tr><th>Nome</th><th>E-mail</th><th>Celular</th><th>Imobiliária</th><th>Código</th><th>Inscrição</th><th>Presença</th><th /></tr></thead>
              <tbody>
                {filtrados.map((p) => (
                  <tr key={p.id}>
                    <td>{p.nome}</td><td>{p.email ?? '—'}</td><td className="nowrap">{formatarTelefone(p.telefone) || '—'}</td><td>{p.imobiliaria ?? '—'}</td>
                    <td className="mono">{p.codigo ?? '—'}</td>
                    <td className="nowrap">{p.origem === 'inscricao' ? new Date(p.inscrito_em ?? p.criado_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : p.origem === 'na_hora' ? 'Na hora' : 'Lista'}</td>
                    <td>{p.presente ? <span className="selo spr-aprovada">Presente</span> : <span className="dica">—</span>}</td>
                    <td><button className="icone-botao" aria-label={`Remover ${p.nome}`} onClick={() => remover(p)}><Trash2 size={15} /></button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}

function EditarMeeting({ ev, aoFechar, aoSalvar }: { ev: Evento | null; aoFechar: () => void; aoSalvar: (e: Evento) => void }) {
  const [nome, setNome] = useState(ev?.nome ?? '');
  const [slug, setSlug] = useState(ev?.slug ?? '');
  const [slugManual, setSlugManual] = useState(!!ev);
  const [dataHora, setDataHora] = useState(paraLocal(ev?.data_hora ?? null));
  const [local, setLocal] = useState(ev?.local ?? '');
  const [descricao, setDescricao] = useState(ev?.descricao ?? '');
  const [abertas, setAbertas] = useState(ev?.inscricoes_abertas ?? true);
  const [vagas, setVagas] = useState(ev?.vagas ? String(ev.vagas) : '');
  const [encerra, setEncerra] = useState(paraLocal(ev?.encerra_em ?? null));
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);

  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro(''); setSalvando(true);
    const { data, error } = await supabase.rpc('salvar_meeting', {
      p_id: ev?.id ?? null, p_nome: nome, p_slug: slug, p_data_hora: dataHora ? new Date(dataHora).toISOString() : null,
      p_local: local, p_descricao: descricao, p_abertas: abertas, p_vagas: vagas ? Number(vagas) : null,
      p_encerra_em: encerra ? new Date(encerra).toISOString() : null,
    });
    setSalvando(false);
    if (error) { setErro(erroMeeting(error.message)); return; }
    aoSalvar(data as Evento);
  };

  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo largo" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2>{ev ? 'Editar meeting' : 'Novo meeting'}</h2>
        <div className="campos">
          <label className="largo">Nome do meeting<input value={nome} autoFocus maxLength={120} onChange={(e) => { setNome(e.target.value); if (!slugManual) setSlug(slugDe(e.target.value)); }} /></label>
          <label className="largo">Endereço da página
            <span className="campo-prefixo"><span>{window.location.host}/meeting/</span><input value={slug} onChange={(e) => { setSlugManual(true); setSlug(slugDe(e.target.value)); }} /></span>
          </label>
          <label>Data e hora<input type="datetime-local" value={dataHora} onChange={(e) => setDataHora(e.target.value)} /></label>
          <label>Local<input value={local} onChange={(e) => setLocal(e.target.value)} maxLength={120} placeholder="Ex.: Majuli, Rio Verde" /></label>
          <label className="largo">Descrição (aparece na página)<textarea rows={3} value={descricao} onChange={(e) => setDescricao(e.target.value)} maxLength={1000} /></label>
          <label>Limite de vagas<input type="number" min={1} value={vagas} onChange={(e) => setVagas(e.target.value)} placeholder="Sem limite" /></label>
          <label>Inscrições até<input type="datetime-local" value={encerra} onChange={(e) => setEncerra(e.target.value)} /></label>
          <label className="interruptor largo"><input type="checkbox" checked={abertas} onChange={(e) => setAbertas(e.target.checked)} /><span className="trilho" /><span><strong>Inscrições abertas</strong><br /><small className="dica">Desligue para fechar a página de inscrição</small></span></label>
        </div>
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal" disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar'}</button>
        </div>
      </form>
    </div>
  );
}

