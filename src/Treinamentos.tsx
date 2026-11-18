import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react';
import { Check, Clock, FileDown, Search, Settings, Trash2, UserPlus, X } from 'lucide-react';
import { supabase } from './dados';
import { useDialogos } from './ui';
import type { Perfil } from './util';

interface Treinamento { id: string; nome: string; local: string | null; inscricoes_abertas: boolean }
interface Horario { id: string; inicio: string; limite: number }
interface Vaga { horario_id: string; inscritos: number; presentes: number }
interface Inscricao {
  id: string; horario_id: string; user_id: string | null; nome: string; email: string | null; papel: string | null;
  imobiliaria: string | null; presente: boolean; presenca_em: string | null; incluido_por: string | null; criado_em: string;
}

const TZ = 'America/Sao_Paulo';
const diaDe = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { timeZone: TZ });
const hora = (iso: string) => new Date(iso).toLocaleTimeString('pt-BR', { timeZone: TZ, hour: '2-digit', minute: '2-digit' });
const rotuloDia = (d: string, longo = false) => new Date(`${d}T12:00:00`).toLocaleDateString('pt-BR',
  longo ? { weekday: 'long', day: '2-digit', month: 'long' } : { weekday: 'short', day: '2-digit', month: '2-digit' });
const norm = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

const ERROS: Record<string, string> = {
  HORARIO_LOTADO: 'Esse horário acabou de lotar. Escolha outro.',
  JA_INSCRITO: 'Você já está inscrito em um horário. Para trocar, cancele a inscrição atual primeiro.',
  HORARIO_JA_COMECOU: 'Esse horário já começou.',
  INSCRICOES_ENCERRADAS: 'As inscrições estão encerradas.',
  SO_CORRETOR: 'Só corretores e imobiliárias podem se inscrever.',
  NOME_OBRIGATORIO: 'Informe o nome completo.',
  PRESENCA_JA_CONFIRMADA: 'A presença já foi confirmada; a inscrição não pode mais ser cancelada.',
  SEM_PERMISSAO: 'Você não tem permissão para isso.',
  HORARIO_COM_INSCRITOS: 'Esse horário tem inscritos. Remova as inscrições antes de excluir o horário.',
  HORARIO_NAO_ENCONTRADO: 'Esse horário já tinha sido excluído.',
  FIM_ANTES_DO_INICIO: 'O último horário precisa ser igual ou depois do primeiro.',
  INTERVALO_INVALIDO: 'O intervalo precisa ficar entre 5 e 480 minutos.',
  LIMITE_INVALIDO: 'O limite de pessoas precisa ficar entre 1 e 1000.',
  HORARIO_INVALIDO: 'Informe o dia e o horário.',
  LIMITE_ABAIXO_DOS_INSCRITOS: 'O limite não pode ficar abaixo do número de inscritos.',
};
const msg = (e: { message: string } | null) => (e ? ERROS[e.message] ?? 'Não foi possível concluir. Tente de novo.' : '');

export function Treinamentos({ perfil }: { perfil: Perfil }) {
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const gestor = perfil.papel === 'imobiliaria';
  const { avisar, confirmar } = useDialogos();
  const [treino, setTreino] = useState<Treinamento | null | undefined>(undefined);
  const [horarios, setHorarios] = useState<Horario[]>([]);
  const [vagas, setVagas] = useState<Record<string, Vaga>>({});
  const [inscricoes, setInscricoes] = useState<Inscricao[]>([]);
  const [dia, setDia] = useState('');
  const [ocupado, setOcupado] = useState('');
  const [busca, setBusca] = useState('');
  const [incluir, setIncluir] = useState<Horario | null>(null);
  const [gerando, setGerando] = useState('');
  const [configurar, setConfigurar] = useState(false);

  const carregar = useCallback(async () => {
    const { data: t, error } = await supabase.from('treinamentos').select('*').order('criado_em', { ascending: false }).limit(1).maybeSingle();
    if (error) { setTreino(null); return; }
    setTreino((t as Treinamento) ?? null);
    if (!t) return;
    const [h, v, i] = await Promise.all([
      supabase.from('treinamento_horarios').select('id, inicio, limite').eq('treinamento_id', t.id).order('inicio'),
      supabase.rpc('treinamento_vagas', { p_treinamento: t.id }),
      supabase.from('treinamento_inscricoes').select('*').eq('treinamento_id', t.id).order('nome'),
    ]);
    setHorarios((h.data as Horario[]) ?? []);
    const m: Record<string, Vaga> = {};
    ((v.data as Vaga[]) ?? []).forEach((x) => { m[x.horario_id] = x; });
    setVagas(m);
    setInscricoes((i.data as Inscricao[]) ?? []);
  }, []);

  useEffect(() => {
    carregar();
    const t = setInterval(carregar, 15000);
    const foco = () => carregar();
    window.addEventListener('focus', foco);
    return () => { clearInterval(t); window.removeEventListener('focus', foco); };
  }, [carregar]);

  const dias = useMemo(() => [...new Set(horarios.map((h) => diaDe(h.inicio)))], [horarios]);
  useEffect(() => {
    if (!dia && dias.length) {
      const hoje = new Date().toLocaleDateString('en-CA', { timeZone: TZ });
      setDia(dias.find((d) => d >= hoje) ?? dias[0]);
    }
  }, [dias, dia]);

  const minha = inscricoes.find((i) => i.user_id === perfil.user_id) ?? null;
  const horarioDe = (id: string) => horarios.find((h) => h.id === id);
  const doDia = horarios.filter((h) => diaDe(h.inicio) === dia);
  const manha = doDia.filter((h) => Number(hora(h.inicio).slice(0, 2)) < 12);
  const tarde = doDia.filter((h) => Number(hora(h.inicio).slice(0, 2)) >= 12);

  const inscrever = async (h: Horario) => {
    setOcupado(h.id);
    const { error } = await supabase.rpc('inscrever_treinamento', { p_horario: h.id });
    setOcupado('');
    if (error) { avisar(msg(error), 'erro'); carregar(); return; }
    avisar(`Inscrição confirmada: ${rotuloDia(diaDe(h.inicio))} às ${hora(h.inicio)}.`);
    carregar();
  };
  const cancelar = async (i: Inscricao, deOutro = false) => {
    const h = horarioDe(i.horario_id);
    const ok = await confirmar({
      titulo: deOutro ? `Remover ${i.nome}?` : 'Cancelar sua inscrição?',
      texto: h ? `${rotuloDia(diaDe(h.inicio))} às ${hora(h.inicio)}. A vaga fica livre para outra pessoa.` : '',
      confirmar: deOutro ? 'Remover' : 'Cancelar inscrição', perigo: true,
    });
    if (!ok) return;
    const { error } = await supabase.rpc('cancelar_inscricao_treinamento', { p_id: i.id });
    if (error) { avisar(msg(error), 'erro'); return; }
    avisar(deOutro ? 'Inscrição removida.' : 'Inscrição cancelada. Você já pode escolher outro horário.');
    carregar();
  };
  const marcar = async (i: Inscricao, presente: boolean) => {
    setInscricoes((l) => l.map((x) => (x.id === i.id ? { ...x, presente } : x)));
    const { error } = await supabase.rpc('presenca_treinamento', { p_id: i.id, p_presente: presente });
    if (error) { avisar(msg(error), 'erro'); }
    carregar();
  };
  const alternarAbertas = async () => {
    if (!treino) return;
    const { error } = await supabase.rpc('ajustar_treinamento', { p_treinamento: treino.id, p_abertas: !treino.inscricoes_abertas });
    if (error) { avisar(msg(error), 'erro'); return; }
    carregar();
  };

  const relatorio = async (qual: 'dia' | 'consolidado') => {
    if (!treino) return;
    setGerando(qual);
    try { await gerarPdf({ treino, horarios, inscricoes, dias: qual === 'dia' ? [dia] : dias, consolidado: qual === 'consolidado' }); }
    finally { setGerando(''); }
  };

  if (treino === undefined) return <section className="secao"><h2>Treinamentos</h2><p className="vazio">Carregando…</p></section>;
  if (treino === null) return <section className="secao"><h2>Treinamentos</h2><p className="vazio">Nenhum treinamento disponível no momento.</p></section>;

  const totDia = doDia.reduce((a, h) => a + (vagas[h.id]?.inscritos ?? 0), 0);
  const presDia = doDia.reduce((a, h) => a + (vagas[h.id]?.presentes ?? 0), 0);
  const t = norm(busca.trim());
  const daImob = gestor ? inscricoes.filter((i) => i.user_id !== perfil.user_id) : [];

  const cartao = (h: Horario) => {
    const v = vagas[h.id]?.inscritos ?? 0;
    const livres = Math.max(0, h.limite - v);
    const passou = new Date(h.inicio).getTime() <= Date.now();
    const meu = minha?.horario_id === h.id;
    const lotado = livres === 0;
    const pres = vagas[h.id]?.presentes ?? 0;
    return (
      <div key={h.id} className={`treino-slot${meu ? ' meu' : ''}${lotado ? ' lotado' : ''}${passou ? ' passou' : ''}`}>
        <div className="treino-hora"><Clock size={15} aria-hidden="true" /> {hora(h.inicio)}</div>
        <div className="treino-barra" aria-hidden="true"><span style={{ width: `${Math.min(100, (v / h.limite) * 100)}%` }} /></div>
        <div className="treino-vagas">
          {equipe ? <><strong>{v}</strong> de {h.limite} inscritos{pres ? ` · ${pres} presentes` : ''}</>
            : lotado ? <strong>Lotado</strong> : <><strong>{livres}</strong> {livres === 1 ? 'vaga' : 'vagas'}</>}
        </div>
        {!equipe && (
          meu ? (
            <button className="botao pequeno" onClick={() => cancelar(minha!)} disabled={passou || minha!.presente}>Cancelar inscrição</button>
          ) : (
            <button className="botao pequeno principal" onClick={() => inscrever(h)}
              disabled={!!minha || lotado || passou || !treino.inscricoes_abertas || ocupado === h.id}
              title={minha ? 'Você já está inscrito em outro horário. Cancele para trocar.' : undefined}>
              {ocupado === h.id ? 'Inscrevendo…' : passou ? 'Encerrado' : lotado ? 'Lotado' : 'Inscrever-me'}
            </button>
          )
        )}
        {meu && <span className="treino-selo"><Check size={13} /> Sua inscrição</span>}
      </div>
    );
  };

  return (
    <section className="secao larga">
      <div className="secao-topo">
        <div>
          <h2>Treinamentos</h2>
          <p className="sub">{treino.nome}{treino.local ? ` · ${treino.local}` : ''}. Até {Math.max(0, ...horarios.map((h) => h.limite))} pessoas por turma.</p>
        </div>
        {equipe && (
          <div className="acoes-linha">
            {perfil.papel === 'admin' && <button className="botao" onClick={() => setConfigurar(true)}><Settings size={16} /> Configurar horários</button>}
            {perfil.papel === 'admin' && <button className="botao" onClick={alternarAbertas}>{treino.inscricoes_abertas ? 'Encerrar inscrições' : 'Reabrir inscrições'}</button>}
            <button className="botao" onClick={() => relatorio('dia')} disabled={!!gerando}><FileDown size={16} /> {gerando === 'dia' ? 'Gerando…' : 'Relatório do dia'}</button>
            <button className="botao principal" onClick={() => relatorio('consolidado')} disabled={!!gerando}><FileDown size={16} /> {gerando === 'consolidado' ? 'Gerando…' : 'Consolidado'}</button>
          </div>
        )}
      </div>

      {!equipe && (
        <div className={`treino-aviso${minha ? ' ok' : ''}`}>
          {minha ? (() => {
            const h = horarioDe(minha.horario_id);
            return <p><strong>Você está inscrito:</strong> {h ? `${rotuloDia(diaDe(h.inicio), true)}, às ${hora(h.inicio)}` : ''}{minha.presente ? ' · presença confirmada' : ''}. Para trocar de horário, cancele a inscrição e escolha outro.</p>;
          })() : <p>{treino.inscricoes_abertas ? 'Escolha um horário e clique em Inscrever-me. Cada pessoa se inscreve em um único horário.' : 'As inscrições estão encerradas.'}</p>}
        </div>
      )}

      <div className="segmentado treino-dias" role="tablist">
        {dias.map((d) => (
          <button key={d} role="tab" aria-selected={dia === d} className={dia === d ? 'ativo' : ''} onClick={() => setDia(d)}>
            {rotuloDia(d)}
          </button>
        ))}
      </div>
      {equipe && <p className="sub treino-resumo"><strong>{totDia}</strong> inscritos e <strong>{presDia}</strong> presentes em {rotuloDia(dia, true)}.</p>}

      {[['Manhã', manha], ['Tarde', tarde]].map(([rot, lista]) => (lista as Horario[]).length > 0 && (
        <div key={rot as string} className="treino-periodo">
          <h3>{rot as string}</h3>
          <div className="treino-grade">{(lista as Horario[]).map(cartao)}</div>
        </div>
      ))}

      {gestor && (
        <div className="cartao treino-imob">
          <h3>Inscritos da sua imobiliária</h3>
          {daImob.length === 0 ? <p className="vazio">Nenhum corretor da sua imobiliária se inscreveu ainda.</p> : (
            <table className="tabela">
              <thead><tr><th>Nome</th><th>Dia e horário</th><th>Presença</th></tr></thead>
              <tbody>{daImob.slice().sort((a, b) => (horarioDe(a.horario_id)?.inicio ?? '').localeCompare(horarioDe(b.horario_id)?.inicio ?? '')).map((i) => {
                const h = horarioDe(i.horario_id);
                return <tr key={i.id}><td>{i.nome}</td><td>{h ? `${rotuloDia(diaDe(h.inicio))} às ${hora(h.inicio)}` : '—'}</td><td>{i.presente ? 'Presente' : '—'}</td></tr>;
              })}</tbody>
            </table>
          )}
        </div>
      )}

      {equipe && (
        <div className="treino-listas">
          <label className="busca-funil"><Search size={16} /><input placeholder="Buscar inscrito por nome ou imobiliária" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
          {doDia.map((h) => {
            const lista = inscricoes.filter((i) => i.horario_id === h.id && (!t || norm(`${i.nome} ${i.imobiliaria ?? ''}`).includes(t)));
            const total = vagas[h.id]?.inscritos ?? 0;
            if (t && lista.length === 0) return null;
            return (
              <div key={h.id} className="cartao treino-lista">
                <div className="treino-lista-topo">
                  <h3>{hora(h.inicio)} <span className="sub">{total} de {h.limite} · {vagas[h.id]?.presentes ?? 0} presentes</span></h3>
                  <button className="botao pequeno" onClick={() => setIncluir(h)} disabled={total >= h.limite}><UserPlus size={14} /> Incluir</button>
                </div>
                {lista.length === 0 ? <p className="vazio">Ninguém inscrito neste horário.</p> : (
                  <ul className="treino-pessoas">
                    {lista.map((i) => (
                      <li key={i.id} className={i.presente ? 'presente' : ''}>
                        <label className="treino-check">
                          <input type="checkbox" checked={i.presente} onChange={(e) => marcar(i, e.target.checked)} aria-label={`Presença de ${i.nome}`} />
                          <span><strong>{i.nome}</strong><small>{i.imobiliaria ?? 'Sem imobiliária'}{i.incluido_por ? ' · incluído pela equipe' : ''}</small></span>
                        </label>
                        <button className="icone-botao" onClick={() => cancelar(i, true)} aria-label={`Remover ${i.nome}`} title="Remover inscrição"><X size={16} /></button>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            );
          })}
        </div>
      )}
      {incluir && <IncluirNoTreino horario={incluir} aoFechar={() => setIncluir(null)} aoSalvar={() => { setIncluir(null); carregar(); }} />}
      {configurar && <ConfigurarHorarios treino={treino} horarios={horarios} vagas={vagas} diaAtual={dia} aoFechar={() => setConfigurar(false)} aoMudar={carregar} />}
    </section>
  );
}

/** Equipe inclui alguém num horário: um login de corretor ou, se não tiver login, só o nome. */
function IncluirNoTreino({ horario, aoFechar, aoSalvar }: { horario: Horario; aoFechar: () => void; aoSalvar: () => void }) {
  const { avisar } = useDialogos();
  const [logins, setLogins] = useState<{ user_id: string; nome: string; imob: string }[]>([]);
  const [escolhido, setEscolhido] = useState('');
  const [nome, setNome] = useState('');
  const [imob, setImob] = useState('');
  const [filtro, setFiltro] = useState('');
  const [erro, setErro] = useState('');
  useEffect(() => {
    supabase.from('perfis').select('user_id, nome, email, imobiliarias(nome)').in('papel', ['corretor', 'imobiliaria']).then(({ data }) => {
      setLogins(((data as unknown as { user_id: string; nome: string | null; email: string; imobiliarias: { nome: string } | null }[]) ?? [])
        .map((p) => ({ user_id: p.user_id, nome: p.nome || p.email, imob: p.imobiliarias?.nome ?? '' }))
        .sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR')));
    });
  }, []);
  const f = norm(filtro.trim());
  const opcoes = logins.filter((l) => !f || norm(`${l.nome} ${l.imob}`).includes(f)).slice(0, 200);
  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    const { error } = await supabase.rpc('inscrever_treinamento', escolhido
      ? { p_horario: horario.id, p_user: escolhido }
      : { p_horario: horario.id, p_nome: nome, p_imobiliaria: imob });
    if (error) { setErro(error.message === 'JA_INSCRITO' ? 'Essa pessoa já está inscrita em outro horário. Remova a inscrição antiga antes.' : msg(error)); return; }
    avisar('Inscrição incluída.');
    aoSalvar();
  };
  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="inc-treino" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="inc-treino">Incluir no horário das {hora(horario.inicio)}</h2>
        <p className="sub">Escolha um corretor cadastrado ou, se ele não tiver login, informe o nome.</p>
        <div className="campos">
          <label className="largo">Buscar corretor<input value={filtro} onChange={(e) => setFiltro(e.target.value)} placeholder="Nome ou imobiliária" autoFocus /></label>
          <label className="largo">Corretor cadastrado
            <select value={escolhido} onChange={(e) => setEscolhido(e.target.value)}>
              <option value="">Não tem login (informar nome abaixo)</option>
              {opcoes.map((l) => <option key={l.user_id} value={l.user_id}>{l.nome}{l.imob ? ` · ${l.imob}` : ''}</option>)}
            </select>
          </label>
          {!escolhido && (
            <>
              <label className="largo">Nome completo<input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={120} /></label>
              <label className="largo">Imobiliária<input value={imob} onChange={(e) => setImob(e.target.value)} maxLength={80} /></label>
            </>
          )}
        </div>
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal">Incluir</button>
        </div>
      </form>
    </div>
  );
}

const INTERVALOS = [15, 20, 30, 45, 60, 90, 120];
const minutos = (t: string) => { const [h, m] = t.split(':').map(Number); return h * 60 + m; };
const hhmm = (n: number) => `${String(Math.floor(n / 60)).padStart(2, '0')}:${String(n % 60).padStart(2, '0')}`;

/** Administrador cria e exclui horários e muda o limite de cada turma. */
function ConfigurarHorarios({ treino, horarios, vagas, diaAtual, aoFechar, aoMudar }: {
  treino: Treinamento; horarios: Horario[]; vagas: Record<string, Vaga>; diaAtual: string; aoFechar: () => void; aoMudar: () => void;
}) {
  const { avisar, confirmar } = useDialogos();
  const hoje = new Date().toLocaleDateString('en-CA', { timeZone: TZ });
  const [novoDia, setNovoDia] = useState(diaAtual || hoje);
  const [ini, setIni] = useState('09:00');
  const [fim, setFim] = useState('11:30');
  const [intervalo, setIntervalo] = useState(30);
  const [limite, setLimite] = useState(String(Math.max(20, ...horarios.map((h) => h.limite))));
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);
  const [limites, setLimites] = useState<Record<string, string>>({});

  const previa = useMemo(() => {
    if (!ini || !fim || minutos(fim) < minutos(ini)) return [];
    const l: string[] = [];
    for (let m = minutos(ini); m <= minutos(fim) && l.length < 200; m += intervalo) l.push(hhmm(m));
    return l;
  }, [ini, fim, intervalo]);
  const existentes = new Set(horarios.filter((h) => diaDe(h.inicio) === novoDia).map((h) => hora(h.inicio)));
  const novos = previa.filter((h) => !existentes.has(h));
  const porDia = useMemo(() => {
    const m = new Map<string, Horario[]>();
    horarios.forEach((h) => { const d = diaDe(h.inicio); m.set(d, [...(m.get(d) ?? []), h]); });
    return [...m.entries()];
  }, [horarios]);
  const inscritos = (h: Horario) => vagas[h.id]?.inscritos ?? 0;

  const adicionar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (!novos.length) { setErro(previa.length ? 'Esses horários já existem nesse dia.' : 'Confira o primeiro e o último horário.'); return; }
    setSalvando(true);
    const { data, error } = await supabase.rpc('adicionar_horarios_treinamento', {
      p_treinamento: treino.id, p_dia: novoDia, p_inicio: ini, p_fim: fim, p_intervalo: intervalo, p_limite: Number(limite),
    });
    setSalvando(false);
    if (error) { setErro(msg(error)); return; }
    avisar(`${data ?? novos.length} horário(s) adicionado(s) em ${rotuloDia(novoDia)}.`);
    aoMudar();
  };
  const remover = async (h: Horario) => {
    const ok = await confirmar({ titulo: `Excluir o horário das ${hora(h.inicio)}?`, texto: `${rotuloDia(diaDe(h.inicio), true)}. Ele deixa de aparecer para os corretores.`, confirmar: 'Excluir', perigo: true });
    if (!ok) return;
    const { error } = await supabase.rpc('remover_horario_treinamento', { p_horario: h.id });
    if (error) { avisar(msg(error), 'erro'); return; }
    avisar('Horário excluído.');
    aoMudar();
  };
  const removerVazios = async (d: string, lista: Horario[]) => {
    const vazios = lista.filter((h) => inscritos(h) === 0);
    if (!vazios.length) return;
    const ok = await confirmar({
      titulo: `Excluir ${vazios.length} horário(s) sem inscritos?`,
      texto: `${rotuloDia(d, true)}. Os horários com inscritos continuam.`, confirmar: 'Excluir', perigo: true,
    });
    if (!ok) return;
    for (const h of vazios) {
      const { error } = await supabase.rpc('remover_horario_treinamento', { p_horario: h.id });
      if (error && error.message !== 'HORARIO_NAO_ENCONTRADO') { avisar(msg(error), 'erro'); break; }
    }
    aoMudar();
  };
  const salvarLimite = async (h: Horario) => {
    const v = limites[h.id];
    if (v === undefined || Number(v) === h.limite) return;
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1) { avisar('Informe um número inteiro de pessoas.', 'erro'); setLimites((l) => ({ ...l, [h.id]: String(h.limite) })); return; }
    const { error } = await supabase.rpc('ajustar_limite_horario', { p_horario: h.id, p_limite: n });
    if (error) {
      avisar(error.message === 'LIMITE_ABAIXO_DOS_INSCRITOS' ? `Esse horário já tem ${inscritos(h)} inscritos; o limite não pode ser menor.` : msg(error), 'erro');
      setLimites((l) => ({ ...l, [h.id]: String(h.limite) }));
      return;
    }
    aoMudar();
  };

  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <div className="dialogo treino-config" role="dialog" aria-modal="true" aria-labelledby="cfg-treino" onClick={(e) => e.stopPropagation()}>
        <div className="dialogo-topo">
          <h2 id="cfg-treino">Configurar horários</h2>
          <button className="icone-botao" onClick={aoFechar} aria-label="Fechar"><X size={20} /></button>
        </div>

        <form className="treino-config-novo" onSubmit={adicionar}>
          <h3>Adicionar horários</h3>
          <div className="campos">
            <label>Dia<input type="date" value={novoDia} onChange={(e) => setNovoDia(e.target.value)} required /></label>
            <label>Primeiro horário<input type="time" value={ini} onChange={(e) => setIni(e.target.value)} required /></label>
            <label>Último horário<input type="time" value={fim} onChange={(e) => setFim(e.target.value)} required /></label>
            <label>A cada
              <select value={intervalo} onChange={(e) => setIntervalo(Number(e.target.value))}>
                {INTERVALOS.map((m) => <option key={m} value={m}>{m < 60 ? `${m} minutos` : m === 60 ? '1 hora' : `${m / 60} horas`.replace('.', ',')}</option>)}
              </select>
            </label>
            <label>Pessoas por turma<input type="number" min={1} max={1000} value={limite} onChange={(e) => setLimite(e.target.value)} required /></label>
          </div>
          <p className="sub">
            {novos.length
              ? <>Serão criados <strong>{novos.length}</strong> horário(s): {novos.slice(0, 14).join(', ')}{novos.length > 14 ? '…' : ''}.{previa.length > novos.length ? ` ${previa.length - novos.length} já existe(m) e fica(m) como está(ão).` : ''}</>
              : previa.length ? 'Todos esses horários já existem nesse dia.' : 'O último horário precisa ser igual ou depois do primeiro.'}
          </p>
          {erro && <p className="erro">{erro}</p>}
          <div className="dialogo-acoes"><button className="botao principal" disabled={salvando || !novos.length}>{salvando ? 'Adicionando…' : 'Adicionar horários'}</button></div>
        </form>

        <div className="treino-config-lista">
          <h3>Horários cadastrados</h3>
          {!porDia.length && <p className="vazio">Nenhum horário cadastrado.</p>}
          {porDia.map(([d, lista]) => (
            <div key={d} className="treino-config-dia">
              <div className="treino-config-dia-topo">
                <strong>{rotuloDia(d, true)}</strong>
                <span className="sub">{lista.length} horário(s), {lista.reduce((a, h) => a + inscritos(h), 0)} inscritos</span>
                {lista.some((h) => inscritos(h) === 0) && <button className="botao pequeno" onClick={() => removerVazios(d, lista)}><Trash2 size={14} /> Excluir os sem inscritos</button>}
              </div>
              <ul>
                {lista.map((h) => {
                  const n = inscritos(h);
                  return (
                    <li key={h.id}>
                      <span className="treino-config-hora">{hora(h.inicio)}</span>
                      <span className="sub">{n} inscrito(s)</span>
                      <label className="treino-config-limite">Limite
                        <input type="number" min={Math.max(1, n)} value={limites[h.id] ?? String(h.limite)}
                          onChange={(e) => setLimites((l) => ({ ...l, [h.id]: e.target.value }))}
                          onBlur={() => salvarLimite(h)} onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); }} />
                      </label>
                      <button className="icone-botao" onClick={() => remover(h)} disabled={n > 0}
                        aria-label={`Excluir ${hora(h.inicio)}`} title={n > 0 ? 'Tem inscritos: remova as inscrições antes' : 'Excluir horário'}><Trash2 size={16} /></button>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------
// Relatórios em PDF: do dia ou consolidado dos dias
// ---------------------------------------------------------------------
async function gerarPdf({ treino, horarios, inscricoes, dias, consolidado }: {
  treino: Treinamento; horarios: Horario[]; inscricoes: Inscricao[]; dias: string[]; consolidado: boolean;
}) {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ unit: 'mm', format: 'a4' });
  const L = doc.internal.pageSize.getWidth();
  const M = 14;
  const escuro: [number, number, number] = [29, 30, 25];
  const cinza: [number, number, number] = [110, 104, 98];
  const destaque: [number, number, number] = [240, 127, 64];
  const hs = horarios.filter((h) => dias.includes(diaDe(h.inicio)));
  const ids = new Set(hs.map((h) => h.id));
  const ins = inscricoes.filter((i) => ids.has(i.horario_id));
  const pres = ins.filter((i) => i.presente);
  const hDe = (id: string) => hs.find((h) => h.id === id)!;

  doc.setFillColor(...destaque); doc.rect(M, 14, 3, 16, 'F');
  doc.setFont('helvetica', 'bold'); doc.setFontSize(18); doc.setTextColor(...escuro);
  doc.text(consolidado ? 'Treinamento: relatório consolidado' : 'Treinamento: relatório do dia', M + 7, 21);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(11); doc.setTextColor(...cinza);
  doc.text([treino.nome, dias.map((d) => rotuloDia(d, !consolidado)).join(' e ')].join('  ·  '), M + 7, 28);
  doc.setFontSize(9);
  doc.text(`Gerado em ${new Date().toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}`, L - M, 21, { align: 'right' });

  const caixas: [string, string][] = [
    [String(ins.length), 'inscritos'],
    [String(pres.length), 'presentes'],
    [String(ins.length - pres.length), 'ausentes'],
    [ins.length ? `${Math.round((pres.length / ins.length) * 100)}%` : '0%', 'comparecimento'],
  ];
  const larg = (L - 2 * M - 3 * 4) / 4;
  caixas.forEach(([n, r], k) => {
    const x = M + k * (larg + 4);
    doc.setFillColor(244, 241, 238); doc.setDrawColor(218, 211, 204);
    doc.roundedRect(x, 36, larg, 20, 2, 2, 'FD');
    doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.setTextColor(...escuro); doc.text(n, x + 5, 46);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(...cinza); doc.text(r, x + 5, 52);
  });

  const estilo = { fontSize: 8.5, cellPadding: 1.8, textColor: escuro, lineColor: [225, 219, 212] as [number, number, number], lineWidth: 0.1 };
  const cab = { fillColor: escuro, textColor: [255, 255, 255] as [number, number, number], fontStyle: 'bold' as const };
  let y = 64;

  // por dia (consolidado) e por horário
  if (consolidado) {
    autoTable(doc, {
      startY: y, margin: { left: M, right: M }, styles: estilo, headStyles: cab,
      head: [['Dia', 'Inscritos', 'Presentes', 'Ausentes', 'Comparecimento']],
      body: dias.map((d) => {
        const l = ins.filter((i) => diaDe(hDe(i.horario_id).inicio) === d);
        const p = l.filter((i) => i.presente).length;
        return [rotuloDia(d, true), l.length, p, l.length - p, l.length ? `${Math.round((p / l.length) * 100)}%` : '—'];
      }),
    });
    y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 8;
  }
  autoTable(doc, {
    startY: y, margin: { left: M, right: M }, styles: estilo, headStyles: cab,
    head: [[...(consolidado ? ['Dia'] : []), 'Horário', 'Vagas', 'Inscritos', 'Presentes']],
    body: hs.map((h) => {
      const l = ins.filter((i) => i.horario_id === h.id);
      return [...(consolidado ? [rotuloDia(diaDe(h.inicio))] : []), hora(h.inicio), h.limite, l.length, l.filter((i) => i.presente).length];
    }),
  });
  y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 8;

  // por imobiliária
  const porImob = new Map<string, { i: number; p: number }>();
  ins.forEach((x) => { const k = x.imobiliaria || 'Sem imobiliária'; const c = porImob.get(k) ?? { i: 0, p: 0 }; c.i++; if (x.presente) c.p++; porImob.set(k, c); });
  autoTable(doc, {
    startY: y, margin: { left: M, right: M }, styles: estilo, headStyles: cab,
    head: [['Imobiliária', 'Inscritos', 'Presentes', 'Comparecimento']],
    body: [...porImob.entries()].sort((a, b) => b[1].p - a[1].p || a[0].localeCompare(b[0], 'pt-BR'))
      .map(([k, c]) => [k, c.i, c.p, `${Math.round((c.p / c.i) * 100)}%`]),
  });

  // lista nominal
  doc.addPage();
  doc.setFont('helvetica', 'bold'); doc.setFontSize(13); doc.setTextColor(...escuro);
  doc.text('Lista de participantes', M, 18);
  autoTable(doc, {
    startY: 24, margin: { left: M, right: M }, styles: estilo, headStyles: cab,
    head: [['#', 'Nome', 'Imobiliária', ...(consolidado ? ['Dia'] : []), 'Horário', 'Presença']],
    body: ins.slice().sort((a, b) => hDe(a.horario_id).inicio.localeCompare(hDe(b.horario_id).inicio) || a.nome.localeCompare(b.nome, 'pt-BR'))
      .map((i, k) => {
        const h = hDe(i.horario_id);
        return [k + 1, i.nome, i.imobiliaria || 'Sem imobiliária', ...(consolidado ? [rotuloDia(diaDe(h.inicio))] : []), hora(h.inicio), i.presente ? 'Presente' : 'Ausente'];
      }),
    didParseCell: (c) => {
      if (c.section === 'body' && c.column.index === c.table.columns.length - 1) {
        c.cell.styles.textColor = c.cell.raw === 'Presente' ? [30, 120, 60] : [170, 60, 50];
        c.cell.styles.fontStyle = 'bold';
      }
    },
  });
  const nome = consolidado ? 'treinamento-consolidado' : `treinamento-${dias[0]}`;
  doc.save(`${nome}.pdf`);
}
