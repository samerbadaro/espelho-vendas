import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react';
import { ArrowLeft, CalendarDays, Download, MapPin, Pencil, Plus, Printer, Trash2, Users, X } from 'lucide-react';
import { supabase } from './dados';
import { formatarTelefone, ir, type Perfil } from './util';
import { useDialogos } from './ui';

interface Rodada {
  id: string; nome: string; data_hora: string; local: string | null; observacoes: string | null;
  limite_clientes: number; inscricoes_abertas: boolean; todas_imobiliarias: boolean;
}
interface Vagas { rodada_id: string; clientes: number; pessoas: number }
interface Inscricao {
  id: string; rodada_id: string; cliente_nome: string; pessoas: number; telefone: string | null; observacao: string | null;
  imobiliaria_id: string | null; corretor_id: string | null; corretor_nome: string | null; criado_em: string;
  imobiliarias: { nome: string } | null;
}
interface Imob { id: string; nome: string }

const ERROS: Record<string, string> = {
  SEM_PERMISSAO: 'Você não tem permissão para isso.',
  NOME_OBRIGATORIO: 'Informe o nome (pelo menos 3 letras).',
  DATA_OBRIGATORIA: 'Informe a data e a hora da rodada.',
  LIMITE_INVALIDO: 'O limite precisa ser de pelo menos 1 cliente.',
  IMOBILIARIAS_OBRIGATORIAS: 'Escolha pelo menos uma imobiliária ou marque "Todas as imobiliárias".',
  LIMITE_ABAIXO_DOS_CONFIRMADOS: 'O limite não pode ficar abaixo da quantidade de clientes já confirmados.',
  RODADA_NAO_ENCONTRADA: 'Rodada não encontrada ou não liberada para a sua imobiliária.',
  INSCRICOES_ENCERRADAS: 'As confirmações desta rodada estão encerradas. Fale com a Sec. Vendas.',
  RODADA_JA_ACONTECEU: 'Esta rodada já aconteceu.',
  PESSOAS_INVALIDO: 'Informe quantas pessoas vêm, de 1 a 20.',
  RODADA_LOTADA: 'As vagas desta rodada acabaram. Fale com a Sec. Vendas.',
  CLIENTE_JA_CONFIRMADO: 'Este cliente já está confirmado nesta rodada.',
  INSCRICAO_NAO_ENCONTRADA: 'Confirmação não encontrada.',
};
const mensagem = (e: { message: string } | null) => (e ? ERROS[e.message] ?? 'Não foi possível salvar. Tente novamente.' : '');

const dataLonga = (iso: string) => {
  const d = new Date(iso);
  const dia = d.toLocaleDateString('pt-BR', { weekday: 'long', day: '2-digit', month: 'long' });
  return `${dia.charAt(0).toUpperCase()}${dia.slice(1)}, às ${d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}`;
};
const paraCampoData = (iso: string) => {
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
};

function situacao(r: Rodada, v?: Vagas) {
  const ocupadas = v?.clientes ?? 0;
  if (new Date(r.data_hora) < new Date()) return { texto: 'Realizada', classe: 'sr-realizada' };
  if (!r.inscricoes_abertas) return { texto: 'Confirmações encerradas', classe: 'sr-encerrada' };
  if (ocupadas >= r.limite_clientes) return { texto: 'Lotada', classe: 'sr-lotada' };
  return { texto: 'Confirmações abertas', classe: 'sr-aberta' };
}

function BarraVagas({ r, v }: { r: Rodada; v?: Vagas }) {
  const ocupadas = v?.clientes ?? 0;
  const pct = Math.min(100, (ocupadas / r.limite_clientes) * 100);
  return (
    <div className="vagas">
      <div className="vagas-texto">
        <span className="vagas-principal"><strong>{ocupadas} de {r.limite_clientes}</strong> clientes confirmados</span>
        <span>{v?.pessoas ?? 0} {(v?.pessoas ?? 0) === 1 ? 'pessoa' : 'pessoas'} no total</span>
      </div>
      <div className="vagas-barra" role="progressbar" aria-valuenow={ocupadas} aria-valuemin={0} aria-valuemax={r.limite_clientes}>
        <span style={{ width: `${pct}%` }} className={ocupadas >= r.limite_clientes ? 'cheia' : ''} />
      </div>
    </div>
  );
}

// =====================================================================
// Lista de rodadas
// =====================================================================
export function Rodadas({ perfil }: { perfil: Perfil }) {
  const admin = perfil.papel === 'admin';
  const [rodadas, setRodadas] = useState<Rodada[] | null>(null);
  const [vagas, setVagas] = useState<Record<string, Vagas>>({});
  const [liberadas, setLiberadas] = useState<Record<string, string[]>>({});
  const [imobs, setImobs] = useState<Imob[]>([]);
  const [editando, setEditando] = useState<Rodada | 'nova' | null>(null);

  const carregar = useCallback(async () => {
    const [r, v] = await Promise.all([
      supabase.from('rodadas').select('*').order('data_hora', { ascending: true }),
      supabase.rpc('rodadas_vagas'),
    ]);
    setRodadas((r.data as Rodada[]) ?? []);
    setVagas(Object.fromEntries(((v.data as Vagas[]) ?? []).map((x) => [x.rodada_id, x])));
    if (admin) {
      const [ri, im] = await Promise.all([
        supabase.from('rodadas_imobiliarias').select('rodada_id, imobiliaria_id'),
        supabase.from('imobiliarias').select('id, nome').eq('ativa', true).order('nome'),
      ]);
      const m: Record<string, string[]> = {};
      ((ri.data as { rodada_id: string; imobiliaria_id: string }[]) ?? []).forEach((x) => (m[x.rodada_id] ??= []).push(x.imobiliaria_id));
      setLiberadas(m);
      setImobs((im.data as Imob[]) ?? []);
    }
  }, [admin]);
  useEffect(() => { carregar(); }, [carregar]);

  const agora = Date.now();
  const proximas = (rodadas ?? []).filter((r) => new Date(r.data_hora).getTime() >= agora - 12 * 3600_000);
  const passadas = (rodadas ?? []).filter((r) => new Date(r.data_hora).getTime() < agora - 12 * 3600_000).reverse();
  const nomeImob = (id: string) => imobs.find((i) => i.id === id)?.nome ?? '';

  const cartao = (r: Rodada) => {
    const s = situacao(r, vagas[r.id]);
    return (
      <button key={r.id} className="rodada-cartao" onClick={() => ir(`/painel/rodadas/${r.id}`)}>
        <div className="rodada-cabeca">
          <h3>{r.nome}</h3>
          <span className={`selo ${s.classe}`}>{s.texto}</span>
        </div>
        <p className="rodada-info"><CalendarDays size={15} />{dataLonga(r.data_hora)}</p>
        {r.local && <p className="rodada-info"><MapPin size={15} />{r.local}</p>}
        {admin && (
          <p className="rodada-info"><Users size={15} />
            {r.todas_imobiliarias ? 'Todas as imobiliárias' : (liberadas[r.id] ?? []).map(nomeImob).filter(Boolean).join(', ') || '—'}
          </p>
        )}
        <BarraVagas r={r} v={vagas[r.id]} />
      </button>
    );
  };

  return (
    <section className="secao">
      <div className="secao-topo">
        <div>
          <h2>Rodadas de negócios</h2>
          <p className="sub">{admin ? 'Crie rodadas, escolha as imobiliárias convidadas e acompanhe as confirmações.' : 'Confirme seus clientes nas rodadas liberadas para a sua imobiliária.'}</p>
        </div>
        {admin && <button className="botao principal" onClick={() => setEditando('nova')}><Plus size={16} /> Nova rodada</button>}
      </div>

      {rodadas == null ? <p className="vazio">Carregando…</p> : rodadas.length === 0 ? (
        <div className="cartao vazio-grande">
          <p>{admin ? 'Nenhuma rodada criada ainda. Use "Nova rodada" para criar a primeira.' : 'Nenhuma rodada liberada para a sua imobiliária no momento.'}</p>
        </div>
      ) : (
        <>
          {proximas.length > 0 && <div className="rodadas-grade">{proximas.map(cartao)}</div>}
          {passadas.length > 0 && (
            <>
              <h3 className="titulo-grupo">Rodadas realizadas</h3>
              <div className="rodadas-grade passadas">{passadas.map(cartao)}</div>
            </>
          )}
        </>
      )}

      {editando && (
        <FormRodada
          rodada={editando === 'nova' ? null : editando}
          liberadas={editando === 'nova' ? [] : liberadas[editando.id] ?? []}
          imobs={imobs}
          aoFechar={() => setEditando(null)}
          aoSalvar={(id) => { setEditando(null); carregar(); if (editando === 'nova') ir(`/painel/rodadas/${id}`); }}
        />
      )}
    </section>
  );
}

// =====================================================================
// Criar / editar rodada (administrador)
// =====================================================================
function FormRodada({ rodada, liberadas, imobs, aoFechar, aoSalvar }: {
  rodada: Rodada | null; liberadas: string[]; imobs: Imob[]; aoFechar: () => void; aoSalvar: (id: string) => void;
}) {
  const [nome, setNome] = useState(rodada?.nome ?? '');
  const [data, setData] = useState(rodada ? paraCampoData(rodada.data_hora) : '');
  const [local, setLocal] = useState(rodada?.local ?? '');
  const [obs, setObs] = useState(rodada?.observacoes ?? '');
  const [limite, setLimite] = useState(String(rodada?.limite_clientes ?? 25));
  const [abertas, setAbertas] = useState(rodada?.inscricoes_abertas ?? true);
  const [todas, setTodas] = useState(rodada?.todas_imobiliarias ?? true);
  const [escolhidas, setEscolhidas] = useState<string[]>(liberadas);
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && aoFechar();
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [aoFechar]);

  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (!data) { setErro(ERROS.DATA_OBRIGATORIA); return; }
    setSalvando(true);
    const { data: r, error } = await supabase.rpc('salvar_rodada', {
      p_id: rodada?.id ?? null, p_nome: nome, p_data_hora: new Date(data).toISOString(), p_local: local,
      p_observacoes: obs, p_limite: Number(limite), p_abertas: abertas, p_todas: todas,
      p_imobiliarias: todas ? null : escolhidas,
    });
    setSalvando(false);
    if (error) { setErro(mensagem(error)); return; }
    aoSalvar((r as Rodada).id);
  };

  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="rod-titulo" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <div className="dialogo-topo">
          <h2 id="rod-titulo">{rodada ? 'Editar rodada' : 'Nova rodada de negócios'}</h2>
          <button type="button" className="icone-botao" onClick={aoFechar} aria-label="Fechar"><X size={18} /></button>
        </div>
        <div className="campos">
          <label className="largo">Nome
            <input value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Rodada de negócios Duo Haus" maxLength={120} autoFocus />
          </label>
          <label>Data e hora
            <input type="datetime-local" value={data} onChange={(e) => setData(e.target.value)} />
          </label>
          <label>Limite de clientes
            <input type="number" min={1} max={2000} value={limite} onChange={(e) => setLimite(e.target.value)} />
          </label>
          <label className="largo">Local
            <input value={local} onChange={(e) => setLocal(e.target.value)} placeholder="Stand de vendas" maxLength={200} />
          </label>
          <label className="largo">Observações para os corretores
            <textarea rows={2} value={obs} onChange={(e) => setObs(e.target.value)} maxLength={600} />
          </label>
        </div>

        <fieldset className="grupo-imobs">
          <legend>Imobiliárias convidadas</legend>
          <label className="check"><input type="checkbox" checked={todas} onChange={(e) => setTodas(e.target.checked)} /> Todas as imobiliárias</label>
          {!todas && (
            <div className="lista-check">
              {imobs.length === 0 && <p className="dica">Nenhuma imobiliária ativa cadastrada.</p>}
              {imobs.map((i) => (
                <label key={i.id} className="check">
                  <input type="checkbox" checked={escolhidas.includes(i.id)}
                    onChange={(e) => setEscolhidas((l) => (e.target.checked ? [...l, i.id] : l.filter((x) => x !== i.id)))} />
                  {i.nome}
                </label>
              ))}
            </div>
          )}
          <p className="dica">Só as imobiliárias convidadas e os corretores delas veem esta rodada.</p>
        </fieldset>

        <label className="check"><input type="checkbox" checked={abertas} onChange={(e) => setAbertas(e.target.checked)} /> Confirmações abertas para os corretores</label>

        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal" disabled={salvando}>{salvando ? 'Salvando…' : rodada ? 'Salvar alterações' : 'Criar rodada'}</button>
        </div>
      </form>
    </div>
  );
}

// =====================================================================
// Detalhe da rodada: confirmar clientes e ver a lista
// =====================================================================
export function DetalheRodada({ id, perfil }: { id: string; perfil: Perfil }) {
  const { confirmar, avisar } = useDialogos();
  const admin = perfil.papel === 'admin';
  const equipe = admin || perfil.papel === 'vendas';
  const gestor = perfil.papel === 'imobiliaria';
  const [rodada, setRodada] = useState<Rodada | null | undefined>(undefined);
  const [vagas, setVagas] = useState<Vagas | undefined>();
  const [lista, setLista] = useState<Inscricao[]>([]);
  const [liberadas, setLiberadas] = useState<string[]>([]);
  const [imobs, setImobs] = useState<Imob[]>([]);
  const [editandoRodada, setEditandoRodada] = useState(false);
  const [editando, setEditando] = useState<Inscricao | null>(null);
  const [comTelefone, setComTelefone] = useState(false);

  const carregar = useCallback(async () => {
    const [r, v, l] = await Promise.all([
      supabase.from('rodadas').select('*').eq('id', id).maybeSingle(),
      supabase.rpc('rodadas_vagas'),
      supabase.from('rodada_inscricoes').select('*, imobiliarias(nome)').eq('rodada_id', id).eq('cancelada', false).order('criado_em'),
    ]);
    setRodada((r.data as Rodada) ?? null);
    setVagas(((v.data as Vagas[]) ?? []).find((x) => x.rodada_id === id));
    setLista((l.data as unknown as Inscricao[]) ?? []);
    if (equipe) {
      const [ri, im] = await Promise.all([
        supabase.from('rodadas_imobiliarias').select('imobiliaria_id').eq('rodada_id', id),
        supabase.from('imobiliarias').select('id, nome').eq('ativa', true).order('nome'),
      ]);
      setLiberadas(((ri.data as { imobiliaria_id: string }[]) ?? []).map((x) => x.imobiliaria_id));
      setImobs((im.data as Imob[]) ?? []);
    }
  }, [id, equipe]);
  useEffect(() => { carregar(); }, [carregar]);

  // atualiza sozinho quando outros corretores confirmam
  useEffect(() => {
    const canal = supabase.channel(`rodada-${id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rodada_inscricoes', filter: `rodada_id=eq.${id}` }, () => carregar())
      .subscribe();
    return () => { supabase.removeChannel(canal); };
  }, [id, carregar]);

  const totais = useMemo(() => ({ clientes: lista.length, pessoas: lista.reduce((a, x) => a + x.pessoas, 0) }), [lista]);

  if (rodada === undefined) return <section className="secao"><p className="vazio">Carregando…</p></section>;
  if (rodada === null) {
    return (
      <section className="secao">
        <p className="vazio">Rodada não encontrada ou não liberada para a sua imobiliária.</p>
        <button className="botao" onClick={() => ir('/painel/rodadas')}><ArrowLeft size={16} /> Voltar</button>
      </section>
    );
  }

  const s = situacao(rodada, vagas);
  const realizada = new Date(rodada.data_hora) < new Date();
  const lotada = (vagas?.clientes ?? 0) >= rodada.limite_clientes;
  const podeConfirmar = equipe ? !lotada : rodada.inscricoes_abertas && !realizada && !lotada;
  const podeAlterar = (i: Inscricao) => equipe || gestor || i.corretor_id === perfil.user_id;
  const alteravelAgora = equipe || (rodada.inscricoes_abertas && !realizada);

  const cancelar = async (i: Inscricao) => {
    if (!(await confirmar({ titulo: `Cancelar a confirmação de ${i.cliente_nome}?`, texto: 'A vaga volta a ficar livre para outro cliente.', confirmar: 'Cancelar confirmação', perigo: true }))) return;
    const { error } = await supabase.rpc('cancelar_cliente_rodada', { p_id: i.id });
    if (error) { avisar(mensagem(error), 'erro'); return; }
    avisar('Confirmação cancelada.'); carregar();
  };

  const excluir = async () => {
    if (!(await confirmar({ titulo: `Excluir a rodada "${rodada.nome}"?`, texto: lista.length ? `Os ${lista.length} clientes confirmados também serão apagados.` : 'A rodada será apagada.', confirmar: 'Excluir rodada', perigo: true }))) return;
    const { error } = await supabase.rpc('excluir_rodada', { p_id: rodada.id });
    if (error) { avisar(mensagem(error), 'erro'); return; }
    avisar('Rodada excluída.'); ir('/painel/rodadas');
  };

  const baixar = () => {
    const cab = ['Cliente', 'Pessoas', ...(comTelefone ? ['Telefone'] : []), 'Imobiliária', 'Corretor', 'Observação', 'Confirmado em'];
    const linhas = lista.map((i) => [
      i.cliente_nome, i.pessoas, ...(comTelefone ? [formatarTelefone(i.telefone)] : []), i.imobiliarias?.nome ?? '',
      i.corretor_nome ?? '', i.observacao ?? '', new Date(i.criado_em).toLocaleString('pt-BR'),
    ]);
    const csv = [cab, ...linhas].map((l) => l.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(';')).join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }));
    a.download = `rodada-${rodada.nome.toLowerCase().normalize('NFD').replace(/[^a-z0-9]+/g, '-')}.csv`;
    a.click(); URL.revokeObjectURL(a.href);
  };

  const nomeImob = (x: string) => imobs.find((i) => i.id === x)?.nome ?? '';

  return (
    <section className="secao rodada-detalhe">
      <button className="voltar so-tela" onClick={() => ir('/painel/rodadas')}><ArrowLeft size={16} /> Rodadas de negócios</button>

      <div className="secao-topo">
        <div>
          <h2>{rodada.nome}</h2>
          <p className="rodada-info"><CalendarDays size={15} />{dataLonga(rodada.data_hora)}</p>
          {rodada.local && <p className="rodada-info"><MapPin size={15} />{rodada.local}</p>}
          {equipe && (
            <p className="rodada-info"><Users size={15} />
              {rodada.todas_imobiliarias ? 'Todas as imobiliárias' : liberadas.map(nomeImob).filter(Boolean).join(', ')}
            </p>
          )}
        </div>
        <div className="acoes-topo so-tela">
          <span className={`selo grande ${s.classe}`}>{s.texto}</span>
          {admin && <button className="botao" onClick={() => setEditandoRodada(true)}><Pencil size={15} /> Editar</button>}
        </div>
      </div>

      {rodada.observacoes && <p className="rodada-obs">{rodada.observacoes}</p>}

      <div className="cartao so-tela"><BarraVagas r={rodada} v={vagas} /></div>

      {podeConfirmar ? (
        <FormCliente rodadaId={rodada.id} equipe={equipe} imobs={rodada.todas_imobiliarias ? imobs : imobs.filter((i) => liberadas.includes(i.id))}
          aoSalvar={() => carregar()} />
      ) : (
        <div className="cartao aviso-rodada so-tela">
          {realizada ? 'Esta rodada já aconteceu.'
            : lotada ? `As ${rodada.limite_clientes} vagas foram preenchidas.${admin ? ' Para abrir mais vagas, use "Editar" e aumente o limite.' : ' Fale com a Sec. Vendas se precisar de mais vagas.'}`
            : 'As confirmações desta rodada estão encerradas. Fale com a Sec. Vendas.'}
        </div>
      )}

      <div className="cartao">
        <div className="cartao-topo">
          <h3>{equipe ? 'Clientes confirmados' : gestor ? 'Clientes confirmados pela sua imobiliária' : 'Seus clientes confirmados'}</h3>
          {equipe && lista.length > 0 && (
            <div className="acoes-lista so-tela">
              <label className="check pequeno"><input type="checkbox" checked={comTelefone} onChange={(e) => setComTelefone(e.target.checked)} /> Incluir telefone</label>
              <button className="botao pequeno" onClick={baixar}><Download size={14} /> Baixar lista</button>
              <button className="botao pequeno" onClick={() => window.print()}><Printer size={14} /> Imprimir</button>
            </div>
          )}
        </div>
        {lista.length === 0 ? <p className="vazio">Nenhum cliente confirmado ainda.</p> : (
          <div className="tabela-rolagem">
            <table className="tabela compacta lista-rodada">
              <thead>
                <tr>
                  <th>#</th><th>Cliente</th><th className="num">Pessoas</th>
                  {(!equipe || comTelefone) && <th>Telefone</th>}
                  {(equipe || gestor) && <th>Imobiliária / corretor</th>}
                  <th>Observação</th>
                  {equipe && <th className="so-impressao">Presença</th>}
                  <th className="so-tela" />
                </tr>
              </thead>
              <tbody>
                {lista.map((i, n) => (
                  <tr key={i.id}>
                    <td className="mono">{n + 1}</td>
                    <td><strong>{i.cliente_nome}</strong></td>
                    <td className="num">{i.pessoas}</td>
                    {(!equipe || comTelefone) && <td className="nowrap">{formatarTelefone(i.telefone) || '—'}</td>}
                    {(equipe || gestor) && <td>{i.imobiliarias?.nome ?? '—'}{i.corretor_nome ? <small className="bloco">{i.corretor_nome}</small> : null}</td>}
                    <td>{i.observacao ?? ''}</td>
                    {equipe && <td className="so-impressao caixa-presenca" />}
                    <td className="so-tela acoes-linha">
                      {podeAlterar(i) && alteravelAgora && (
                        <>
                          <button className="icone-botao" onClick={() => setEditando(i)} aria-label={`Editar ${i.cliente_nome}`} title="Editar"><Pencil size={15} /></button>
                          <button className="icone-botao" onClick={() => cancelar(i)} aria-label={`Cancelar ${i.cliente_nome}`} title="Cancelar confirmação"><Trash2 size={15} /></button>
                        </>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={2}>{totais.clientes} {totais.clientes === 1 ? 'cliente' : 'clientes'}</td>
                  <td className="num">{totais.pessoas}</td>
                  <td colSpan={10}>{totais.pessoas === 1 ? 'pessoa' : 'pessoas'}</td>
                </tr>
              </tfoot>
            </table>
          </div>
        )}
      </div>

      {admin && <button className="botao recusar so-tela" onClick={excluir}><Trash2 size={15} /> Excluir rodada</button>}

      {editandoRodada && (
        <FormRodada rodada={rodada} liberadas={liberadas} imobs={imobs}
          aoFechar={() => setEditandoRodada(false)} aoSalvar={() => { setEditandoRodada(false); carregar(); }} />
      )}
      {editando && <EditarCliente insc={editando} aoFechar={() => setEditando(null)} aoSalvar={() => { setEditando(null); carregar(); }} />}
    </section>
  );
}

function FormCliente({ rodadaId, equipe, imobs, aoSalvar }: { rodadaId: string; equipe: boolean; imobs: Imob[]; aoSalvar: () => void }) {
  const { avisar } = useDialogos();
  const [nome, setNome] = useState('');
  const [pessoas, setPessoas] = useState('1');
  const [telefone, setTelefone] = useState('');
  const [obs, setObs] = useState('');
  const [imob, setImob] = useState('');
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);

  const enviar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    setSalvando(true);
    const { error } = await supabase.rpc('confirmar_cliente_rodada', {
      p_rodada: rodadaId, p_cliente: nome, p_pessoas: Number(pessoas), p_telefone: telefone, p_observacao: obs,
      p_imobiliaria: equipe && imob ? imob : null,
    });
    setSalvando(false);
    if (error) { setErro(mensagem(error)); return; }
    avisar(`${nome.trim()} confirmado.`);
    setNome(''); setPessoas('1'); setTelefone(''); setObs('');
    aoSalvar();
  };

  return (
    <form className="cartao so-tela" onSubmit={enviar}>
      <h3>Confirmar cliente</h3>
      <div className="campos campos-cliente">
        <label className="largo">Nome do cliente
          <input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={120} placeholder="Nome completo" />
        </label>
        <label>Quantas pessoas vêm
          <input type="number" min={1} max={20} value={pessoas} onChange={(e) => setPessoas(e.target.value)} />
          <small>Contando o cliente</small>
        </label>
        <label>Telefone (opcional)
          <input value={formatarTelefone(telefone)} onChange={(e) => setTelefone(e.target.value.replace(/\D/g, '').slice(0, 11))} inputMode="tel" placeholder="(64) 99999-9999" />
        </label>
        {equipe && (
          <label>Imobiliária
            <select value={imob} onChange={(e) => setImob(e.target.value)}>
              <option value="">Sem imobiliária (direto)</option>
              {imobs.map((i) => <option key={i.id} value={i.id}>{i.nome}</option>)}
            </select>
          </label>
        )}
        <label className={equipe ? '' : 'largo'}>Observação (opcional)
          <input value={obs} onChange={(e) => setObs(e.target.value)} maxLength={200} />
        </label>
      </div>
      {erro && <p className="erro">{erro}</p>}
      <button className="botao principal" disabled={salvando}><Plus size={16} /> {salvando ? 'Confirmando…' : 'Confirmar cliente'}</button>
    </form>
  );
}

function EditarCliente({ insc, aoFechar, aoSalvar }: { insc: Inscricao; aoFechar: () => void; aoSalvar: () => void }) {
  const [nome, setNome] = useState(insc.cliente_nome);
  const [pessoas, setPessoas] = useState(String(insc.pessoas));
  const [telefone, setTelefone] = useState(insc.telefone ?? '');
  const [obs, setObs] = useState(insc.observacao ?? '');
  const [erro, setErro] = useState('');

  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    const { error } = await supabase.rpc('editar_cliente_rodada', {
      p_id: insc.id, p_cliente: nome, p_pessoas: Number(pessoas), p_telefone: telefone, p_observacao: obs,
    });
    if (error) { setErro(mensagem(error)); return; }
    aoSalvar();
  };

  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="ed-titulo" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="ed-titulo">Editar confirmação</h2>
        <div className="campos">
          <label className="largo">Nome do cliente<input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={120} /></label>
          <label>Quantas pessoas vêm<input type="number" min={1} max={20} value={pessoas} onChange={(e) => setPessoas(e.target.value)} /></label>
          <label>Telefone<input value={formatarTelefone(telefone)} onChange={(e) => setTelefone(e.target.value.replace(/\D/g, '').slice(0, 11))} inputMode="tel" /></label>
          <label className="largo">Observação<input value={obs} onChange={(e) => setObs(e.target.value)} maxLength={200} /></label>
        </div>
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal">Salvar</button>
        </div>
      </form>
    </div>
  );
}
