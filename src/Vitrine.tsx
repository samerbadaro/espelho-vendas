// Vitrine de empreendimentos: porta de entrada do painel quando o login tem mais de um empreendimento.
import { useEffect, useMemo, useState } from 'react';
import { CalendarDays, FileSignature, ListOrdered, LogOut, Plus, Search, Settings, Table2 } from 'lucide-react';
import { supabase } from './dados';
import { type Perfil } from './util';
import { GestaoEmpreendimentos } from './Empreendimentos';
import { entrarNoEmpreendimento } from './rotaEmp';

type Fase = 'pre_lancamento' | 'lancamento' | 'obras' | 'entregue';
export const ROTULO_FASE: Record<Fase, string> = { pre_lancamento: 'Pré-lançamento', lancamento: 'Lançamento', obras: 'Em obras', entregue: 'Entregue' };

interface Card {
  id: string; slug: string; sigla: string; nome: string; ativo: boolean; fase: Fase; cidade: string | null;
  fachada: string | null; logo: string | null; logo_escuro: string | null; cor_primaria: string | null; cor_destaque: string | null;
  entrega: string | null; a_partir: number | null; total: number; status: Record<string, number>; vendas: number;
  vgv_tabela: number; vgv_vendido: number; fila: string | null; proxima_tabela: string | null;
  meeting: { nome: string; data_hora: string } | null; propostas_pendentes: number;
}
interface Consolidado { empreendimentos: number; unidades: number; vendas: number; disponiveis: number; vgv_tabela: number; vgv_vendido: number }

const FAIXAS: { k: string[]; rotulo: string; cor: string }[] = [
  { k: ['disponivel'], rotulo: 'disponíveis', cor: 'var(--disponivel)' },
  { k: ['reservada'], rotulo: 'reservadas', cor: 'var(--reservada)' },
  { k: ['proposta', 'contrato'], rotulo: 'em proposta/contrato', cor: 'var(--proposta)' },
  { k: ['vendida'], rotulo: 'vendidas', cor: 'var(--vendida)' },
  { k: ['bloqueada', 'permutante'], rotulo: 'fora de venda', cor: 'var(--bloqueada)' },
];
const MESES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
const mesAno = (iso: string) => `${MESES[Number(iso.slice(5, 7)) - 1]}/${iso.slice(0, 4)}`;
const dia = (iso: string) => new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });
const brl = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL', maximumFractionDigits: 0 });
const milhoes = (v: number) => (v >= 1e6 ? `R$ ${(v / 1e6).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} mi` : brl(v));
const pct = (a: number, b: number) => (b ? `${((a / b) * 100).toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%` : '0%');

export function Vitrine({ perfil }: { perfil: Perfil }) {
  const admin = perfil.papel === 'admin';
  const equipe = admin || perfil.papel === 'vendas';
  const [dados, setDados] = useState<{ empreendimentos: Card[]; consolidado: Consolidado | null } | null>(null);
  const [erro, setErro] = useState('');
  const [busca, setBusca] = useState('');
  const [fase, setFase] = useState<Fase | ''>('');
  const [gerenciar, setGerenciar] = useState(false);

  const carregar = () => supabase.rpc('vitrine').then(({ data, error }) => {
    if (error) setErro(error.message.includes('function') ? 'O banco ainda não tem a vitrine (migração 113).' : 'Não foi possível carregar os empreendimentos.');
    else setDados(data as never);
  });
  useEffect(() => { carregar(); }, []);

  const lista = useMemo(() => {
    const t = busca.trim().toLowerCase();
    return (dados?.empreendimentos ?? []).filter((e) => (!t || `${e.nome} ${e.sigla} ${e.cidade ?? ''}`.toLowerCase().includes(t)) && (!fase || e.fase === fase));
  }, [dados, busca, fase]);
  const c = dados?.consolidado;
  const muitos = (dados?.empreendimentos.length ?? 0) > 6;

  return (
    <div className="vitrine">
      <header className="vitrine-topo">
        <div>
          <h1>Empreendimentos</h1>
          <p className="sub">{dados ? `${dados.empreendimentos.length} empreendimento${dados.empreendimentos.length === 1 ? '' : 's'} · escolha onde vai trabalhar` : 'Carregando…'}</p>
        </div>
        <div className="vitrine-usuario">
          <span><strong>{perfil.nome || perfil.email}</strong></span>
          <button className="icone-botao" onClick={() => supabase.auth.signOut()} aria-label="Sair" title="Sair"><LogOut size={18} /></button>
        </div>
      </header>

      {erro && <p className="erro">{erro}</p>}

      {equipe && c && c.empreendimentos > 1 && (
        <section className="vitrine-consolidado" aria-label="Incorporadora">
          <div><span>Unidades</span><strong>{c.unidades.toLocaleString('pt-BR')}</strong><small>{c.disponiveis.toLocaleString('pt-BR')} disponíveis</small></div>
          <div><span>Vendas</span><strong>{c.vendas.toLocaleString('pt-BR')}</strong><small>VSO {pct(c.vendas, c.unidades)}</small></div>
          <div><span>VGV de tabela</span><strong>{milhoes(c.vgv_tabela)}</strong><small>todos os empreendimentos</small></div>
          <div><span>VGV vendido</span><strong>{milhoes(c.vgv_vendido)}</strong><small>{pct(c.vgv_vendido, c.vgv_tabela)} do VGV</small></div>
        </section>
      )}

      {muitos && (
        <div className="vitrine-filtros">
          <label className="busca-simples"><Search size={16} /><input placeholder="Buscar empreendimento ou cidade" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
          <select value={fase} onChange={(e) => setFase(e.target.value as Fase | '')}>
            <option value="">Todas as fases</option>
            {(Object.keys(ROTULO_FASE) as Fase[]).map((f) => <option key={f} value={f}>{ROTULO_FASE[f]}</option>)}
          </select>
        </div>
      )}

      <div className="vitrine-grade">
        {lista.map((e) => <CardEmpreendimento key={e.id} e={e} admin={admin} equipe={equipe} />)}
        {admin && dados && (
          <button className="vitrine-novo" onClick={() => setGerenciar(true)}>
            <Plus size={28} />
            <strong>Novo empreendimento</strong>
            <span>ou editar fase, fachada e acessos</span>
          </button>
        )}
      </div>
      {dados && !lista.length && <p className="vazio">Nenhum empreendimento encontrado.</p>}

      {admin && gerenciar && (
        <div className="vitrine-gestao">
          <GestaoEmpreendimentos aoMudar={carregar} aoFechar={() => setGerenciar(false)} />
        </div>
      )}
    </div>
  );
}

function CardEmpreendimento({ e, admin, equipe }: { e: Card; admin: boolean; equipe: boolean }) {
  const soma = (ks: string[]) => ks.reduce((s, k) => s + (e.status[k] ?? 0), 0);
  const entrar = () => entrarNoEmpreendimento(e.slug);
  const avisos: { i: JSX.Element; t: string; forte?: boolean }[] = [];
  if (e.fila) avisos.push({ i: <ListOrdered size={13} />, t: new Date(e.fila) > new Date() ? `Fila de escolha em ${dia(e.fila)}` : 'Fila de escolha aberta', forte: true });
  if (e.proxima_tabela) avisos.push({ i: <Table2 size={13} />, t: `Tabela nova a partir de ${dia(e.proxima_tabela)}` });
  if (e.meeting) avisos.push({ i: <CalendarDays size={13} />, t: `Meeting em ${dia(e.meeting.data_hora)}` });
  if (e.propostas_pendentes) avisos.push({
    i: <FileSignature size={13} />, forte: true,
    t: equipe ? `${e.propostas_pendentes} proposta${e.propostas_pendentes > 1 ? 's' : ''} para analisar` : `${e.propostas_pendentes} proposta${e.propostas_pendentes > 1 ? 's' : ''} devolvida${e.propostas_pendentes > 1 ? 's' : ''}`,
  });
  const fundo = e.cor_primaria || '#1d1d1b';
  return (
    <article className={`vitrine-card${e.ativo ? '' : ' inativo'}`}>
      <button className="vitrine-capa" onClick={entrar} aria-label={`Entrar no ${e.nome}`}
        style={{ backgroundColor: fundo, backgroundImage: e.fachada ? `url("${e.fachada}")` : `linear-gradient(135deg, ${fundo}, color-mix(in srgb, ${fundo} 55%, ${e.cor_destaque || '#888'}))` }}>
        <span className="vitrine-sombra" />
        <span className="vitrine-chips">
          <span className="vitrine-chip">{ROTULO_FASE[e.fase]}</span>
          {!e.ativo && <span className="vitrine-chip">Inativo</span>}
        </span>
        {!e.fachada && (e.logo_escuro
          ? <img className="vitrine-logo-centro" src={e.logo_escuro} alt="" />
          : <span className="vitrine-sigla">{e.sigla}</span>)}
        <span className="vitrine-preco">
          {e.a_partir != null ? <><small>A partir de</small><strong>{brl(e.a_partir)}</strong></> : <small>Sem unidades disponíveis</small>}
        </span>
        {e.fachada && e.logo_escuro && <img className="vitrine-logo" src={e.logo_escuro} alt="" />}
      </button>
      <div className="vitrine-corpo">
        <div className="vitrine-titulo">
          <h3>{e.nome}</h3>
          <span className="vitrine-vso" title="Vendas sobre a oferta"><strong>{pct(e.vendas, e.total)}</strong><small>VSO</small></span>
        </div>
        <p className="sub">{[e.cidade, e.entrega ? `entrega ${mesAno(e.entrega)}` : null, `${e.total} unidades`].filter(Boolean).join(' · ')}</p>
        <div className="vitrine-barra" role="img" aria-label={FAIXAS.map((f) => `${soma(f.k)} ${f.rotulo}`).join(', ')}>
          {FAIXAS.map((f) => { const n = soma(f.k); return n ? <span key={f.rotulo} style={{ flexGrow: n, background: f.cor }} /> : null; })}
        </div>
        <ul className="vitrine-legenda">
          {FAIXAS.map((f) => { const n = soma(f.k); return n || f.k[0] === 'disponivel' ? <li key={f.rotulo}><i style={{ background: f.cor }} />{n} {f.rotulo}</li> : null; })}
        </ul>
        {equipe && <p className="vitrine-vgv">VGV de tabela {milhoes(e.vgv_tabela)} · vendido {milhoes(e.vgv_vendido)}</p>}
        {avisos.length > 0 && (
          <div className="vitrine-avisos">{avisos.map((a) => <span key={a.t} className={a.forte ? 'forte' : ''}>{a.i}{a.t}</span>)}</div>
        )}
      </div>
      <div className="vitrine-acoes">
        <button className="botao principal" onClick={entrar}>Entrar</button>
        {admin && <button className="botao" onClick={() => entrarNoEmpreendimento(e.slug, '/painel/empreendimento')} title="Marca, módulos e dados comerciais"><Settings size={15} /> Configurar</button>}
      </div>
    </article>
  );
}
