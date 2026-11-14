import { useCallback, useEffect, useState, type FormEvent, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import {
  Home, LayoutGrid, FolderOpen, Building2, Users, Settings, LogOut, ExternalLink, Tv, Menu, X, Kanban, Handshake, ClipboardCheck, Library,
} from 'lucide-react';
import {
  supabase, configurado, useEspelho, STATUS, rotuloStatus, formatarArea, formatarDataHora, formatarReais, lerNumero,
  type Unidade, type Status,
} from './dados';
import { Predio, Resumo } from './Predio';
import { Aviso, StatusConexao, useTitulo } from './Publico';
import { ListaPastas, DetalhePasta } from './Pastas';
import { Imobiliarias, Corretores } from './Imobiliarias';
import { Inicio } from './Inicio';
import { Empreendimento } from './Empreendimento';
import { Funil } from './Funil';
import { Rodadas, DetalheRodada } from './Rodadas';
import { Recepcao } from './Recepcao';
import { Portal } from './Portal';
import { useRota, ir, type Perfil } from './util';
import { Logo, useMarca, useDialogos, useSaidaPorInatividade } from './ui';

interface Registro {
  id: number; numero: string; status_anterior: Status | null; status_novo: Status;
  motivo: string | null; usuario_email: string | null; criado_em: string;
  detalhes?: Record<string, unknown> | null;
}

const MINUTOS_INATIVIDADE = 60;

/** Painel: exige login e perfil cadastrado (admin, Sec. Vendas, imobiliária ou corretor). */
export function Painel() {
  const [sessao, setSessao] = useState<Session | null | undefined>(undefined);
  const [perfil, setPerfil] = useState<Perfil | null | undefined>(undefined);
  const [recarga, setRecarga] = useState(0);

  useEffect(() => {
    if (!configurado) { setSessao(null); return; }
    supabase.auth.getSession().then(({ data }) => setSessao(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSessao(s));
    return () => data.subscription.unsubscribe();
  }, []);

  const idUsuario = sessao?.user.id;
  useEffect(() => {
    if (!idUsuario) { setPerfil(sessao === null ? null : undefined); return; }
    supabase.from('perfis').select('user_id, email, nome, papel, imobiliaria_id, trocar_senha').eq('user_id', idUsuario).maybeSingle()
      .then(({ data }) => setPerfil((data as Perfil) ?? null));
  }, [idUsuario, recarga]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!configurado) return <Aviso texto="O sistema ainda não foi conectado ao banco de dados." />;
  if (sessao === undefined) return <Aviso texto="Carregando…" />;
  if (!sessao) return <Login />;
  if (perfil === undefined) return <Aviso texto="Carregando…" />;
  if (!perfil) return <SemAcesso email={sessao.user.email ?? ''} userId={sessao.user.id} />;
  if (perfil.trocar_senha) return <TrocarSenha aoTrocar={() => setRecarga((n) => n + 1)} />;
  return <Casca perfil={perfil} />;
}

/** Login sem perfil: mostra se o cadastro da imobiliária está em análise ou foi recusado. */
function SemAcesso({ email, userId }: { email: string; userId: string }) {
  const [sol, setSol] = useState<{ status: string; motivo: string | null; imobiliaria_nome: string } | null | undefined>(undefined);
  useEffect(() => {
    supabase.from('solicitacoes_imobiliaria').select('status, motivo, imobiliaria_nome').eq('user_id', userId).maybeSingle()
      .then(({ data }) => setSol((data as { status: string; motivo: string | null; imobiliaria_nome: string }) ?? null));
  }, [userId]);
  if (sol === undefined) return <Aviso texto="Carregando…" />;
  return (
    <TelaAcesso>
      {sol?.status === 'pendente' ? (
        <>
          <h1>Cadastro em análise</h1>
          <p className="dica">O cadastro da <b>{sol.imobiliaria_nome}</b> foi recebido e está aguardando a aprovação da administração. Assim que for aprovado, este mesmo login passa a ter acesso.</p>
        </>
      ) : sol?.status === 'recusada' ? (
        <>
          <h1>Cadastro não aprovado</h1>
          <p className="dica">O cadastro da <b>{sol.imobiliaria_nome}</b> não foi aprovado{sol.motivo ? `: ${sol.motivo}` : '.'}</p>
          <p className="dica">Você pode corrigir os dados e enviar de novo em <a href="/cadastro">Cadastro de imobiliária</a>, com o mesmo e-mail.</p>
        </>
      ) : (
        <>
          <h1>Acesso não liberado</h1>
          <p className="dica">O usuário {email} não tem acesso ao painel. Peça a liberação ao administrador.</p>
        </>
      )}
      <button className="botao" onClick={() => supabase.auth.signOut()}>Sair</button>
    </TelaAcesso>
  );
}

/** Tela dividida usada no login e na troca de senha: imagem do empreendimento + formulário. */
export function TelaAcesso({ children }: { children: ReactNode }) {
  const { marca } = useMarca();
  return (
    <div className="acesso">
      <div className="acesso-imagem" style={marca.imagem_login_url ? { backgroundImage: `url(${marca.imagem_login_url})` } : undefined}>
        <div className="acesso-marca">
          <Logo escuro />
          {marca.cidade && <span>{marca.cidade}</span>}
        </div>
      </div>
      <div className="acesso-form">
        <div className="acesso-caixa">{children}</div>
      </div>
    </div>
  );
}

function Login() {
  const [email, setEmail] = useState('');
  const [senha, setSenha] = useState('');
  const [erro, setErro] = useState('');
  const [enviando, setEnviando] = useState(false);

  const entrar = async (e: FormEvent) => {
    e.preventDefault();
    setEnviando(true); setErro('');
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
    if (error) setErro('E-mail ou senha incorretos.');
    setEnviando(false);
  };

  return (
    <TelaAcesso>
      <form className="login" onSubmit={entrar}>
        <h1>Entrar no painel</h1>
        <p className="dica">Acesso para a equipe de vendas, imobiliárias e corretores.</p>
        <label>E-mail<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        <label>Senha<input type="password" autoComplete="current-password" value={senha} onChange={(e) => setSenha(e.target.value)} required /></label>
        {erro && <p className="erro" role="alert">{erro}</p>}
        <button className="botao principal largo" disabled={enviando}>{enviando ? 'Entrando…' : 'Entrar'}</button>
        <p className="dica">Esqueceu a senha? Corretores pedem à imobiliária; imobiliárias pedem ao administrador.</p>
        <p className="dica cadastro-link">Sua imobiliária ainda não tem acesso? <a href="/cadastro">Cadastre a imobiliária</a></p>
      </form>
    </TelaAcesso>
  );
}

function TrocarSenha({ aoTrocar }: { aoTrocar: () => void }) {
  const [senha, setSenha] = useState('');
  const [confirma, setConfirma] = useState('');
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);
  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (senha.length < 8) { setErro('A senha precisa ter pelo menos 8 caracteres.'); return; }
    if (senha !== confirma) { setErro('As duas senhas não são iguais.'); return; }
    setSalvando(true);
    const { error } = await supabase.auth.updateUser({ password: senha });
    if (error) {
      setSalvando(false);
      setErro(/pwned|leak|weak/i.test(error.message)
        ? 'Essa senha é fraca ou já apareceu em vazamentos na internet. Escolha outra.'
        : 'Não foi possível trocar a senha. Tente uma senha diferente.');
      return;
    }
    await supabase.rpc('senha_trocada');
    setSalvando(false); aoTrocar();
  };
  return (
    <TelaAcesso>
      <form className="login" onSubmit={salvar}>
        <h1>Crie sua senha</h1>
        <p className="dica">Você entrou com uma senha provisória. Crie uma senha própria, com pelo menos 8 caracteres.</p>
        <label>Nova senha<input type="password" autoComplete="new-password" value={senha} onChange={(e) => setSenha(e.target.value)} required /></label>
        <label>Repita a nova senha<input type="password" autoComplete="new-password" value={confirma} onChange={(e) => setConfirma(e.target.value)} required /></label>
        {erro && <p className="erro" role="alert">{erro}</p>}
        <button className="botao principal largo" disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar senha'}</button>
        <button type="button" className="botao largo" onClick={() => supabase.auth.signOut()}>Sair</button>
      </form>
    </TelaAcesso>
  );
}

const PAPEL: Record<Perfil['papel'], string> = { admin: 'Administrador', vendas: 'Sec. Vendas', imobiliaria: 'Imobiliária', corretor: 'Corretor' };

/** Estrutura do painel: menu lateral (no celular, barra inferior) e a página da vez. */
function Casca({ perfil }: { perfil: Perfil }) {
  const rota = useRota();
  const { marca } = useMarca();
  const { avisar } = useDialogos();
  const [imob, setImob] = useState('');
  const [menuAberto, setMenuAberto] = useState(false);
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const admin = perfil.papel === 'admin';
  const gestor = perfil.papel === 'imobiliaria';
  const pastasAtivas = marca.modulo_pastas;

  useEffect(() => {
    if (!equipe) supabase.from('imobiliarias').select('nome').maybeSingle()
      .then(({ data }) => setImob((data as { nome: string } | null)?.nome ?? ''));
  }, [equipe]);
  useEffect(() => setMenuAberto(false), [rota]);
  useTitulo(marca.nome_empreendimento ? `Painel, ${marca.nome_empreendimento}` : undefined);

  const sair = useCallback(() => {
    supabase.auth.signOut();
    avisar('Sessão encerrada por inatividade.');
  }, [avisar]);
  useSaidaPorInatividade(MINUTOS_INATIVIDADE, sair);

  type Item = { c: string; r: string; i: ReactNode };
  const menu: Item[] = equipe
    ? [
      { c: '/painel', r: 'Início', i: <Home size={18} /> },
      { c: '/painel/espelho', r: 'Espelho', i: <LayoutGrid size={18} /> },
      ...(pastasAtivas ? [{ c: '/painel/pastas', r: 'Pastas', i: <FolderOpen size={18} /> }, { c: '/painel/funil', r: 'Funil de vendas', i: <Kanban size={18} /> }] : []),
      { c: '/painel/portal', r: 'Portal do Corretor', i: <Library size={18} /> },
      { c: '/painel/rodadas', r: 'Rodadas de negócios', i: <Handshake size={18} /> },
      { c: '/painel/recepcao', r: 'Recepção', i: <ClipboardCheck size={18} /> },
      ...(admin ? [
        { c: '/painel/imobiliarias', r: 'Imobiliárias e logins', i: <Building2 size={18} /> },
        { c: '/painel/empreendimento', r: 'Empreendimento', i: <Settings size={18} /> },
      ] : []),
    ]
    : [
      ...(pastasAtivas ? [{ c: '/painel/pastas', r: 'Pastas', i: <FolderOpen size={18} /> }] : []),
      { c: '/painel/portal', r: 'Portal do Corretor', i: <Library size={18} /> },
      { c: '/painel/rodadas', r: 'Rodadas de negócios', i: <Handshake size={18} /> },
      ...(gestor && pastasAtivas ? [{ c: '/painel/corretores', r: 'Corretores', i: <Users size={18} /> }] : []),
      { c: '/painel/espelho', r: 'Espelho', i: <LayoutGrid size={18} /> },
    ];
  const inicial = menu[0].c;
  const atual = rota === '/painel' ? inicial : rota;
  const ativo = (c: string) => (c === '/painel' ? atual === '/painel' : atual.startsWith(c));

  let pagina: ReactNode;
  const idPasta = atual.match(/^\/painel\/pastas\/([^/]+)$/)?.[1];
  const idRodada = atual.match(/^\/painel\/rodadas\/([^/]+)$/)?.[1];
  const catPortal = atual.match(/^\/painel\/portal(?:\/([a-z_]+))?$/);
  if (catPortal) pagina = <Portal key={catPortal[1] ?? 'inicio'} perfil={perfil} categoria={catPortal[1]} />;
  else if (atual === '/painel/recepcao' && equipe) pagina = <Recepcao />;
  else if (idRodada) pagina = <DetalheRodada key={idRodada} id={idRodada} perfil={perfil} />;
  else if (atual === '/painel/rodadas') pagina = <Rodadas perfil={perfil} />;
  else if (idPasta && pastasAtivas) pagina = <DetalhePasta key={idPasta} id={idPasta} perfil={perfil} />;
  else if (atual === '/painel/pastas' && pastasAtivas) pagina = <ListaPastas perfil={perfil} />;
  else if (atual === '/painel/funil' && equipe && pastasAtivas) pagina = <Funil />;
  else if (atual === '/painel/imobiliarias' && admin) pagina = <Imobiliarias perfil={perfil} />;
  else if (atual === '/painel/empreendimento' && admin) pagina = <Empreendimento />;
  else if (atual === '/painel/corretores' && gestor) pagina = <Corretores perfil={perfil} />;
  else if (atual === '/painel/espelho') pagina = equipe ? <EspelhoEquipe perfil={perfil} /> : <EspelhoSomenteLeitura />;
  else if (atual === '/painel' && equipe) pagina = <Inicio perfil={perfil} />;
  else pagina = equipe ? <Inicio perfil={perfil} /> : pastasAtivas ? <ListaPastas perfil={perfil} /> : <EspelhoSomenteLeitura />;

  const nomeUsuario = equipe ? perfil.nome || perfil.email : gestor ? imob : perfil.nome || perfil.email;
  const subtitulo = equipe ? PAPEL[perfil.papel] : gestor ? 'Imobiliária' : `Corretor, ${imob}`;

  const navegar = (c: string) => (e: React.MouseEvent) => { e.preventDefault(); ir(c); };

  return (
    <div className={`app${menuAberto ? ' menu-aberto' : ''}`}>
      <aside className="lateral" aria-label="Menu principal">
        <div className="lateral-topo">
          <a href={inicial} onClick={navegar(inicial)} className="lateral-logo"><Logo escuro /></a>
          <button className="so-celular icone-botao" onClick={() => setMenuAberto(false)} aria-label="Fechar menu"><X size={20} /></button>
        </div>
        <nav className="lateral-menu">
          {menu.map((m) => (
            <a key={m.c} href={m.c} className={ativo(m.c) ? 'ativo' : ''} aria-current={ativo(m.c) ? 'page' : undefined} onClick={navegar(m.c)}>
              {m.i}<span>{m.r}</span>
            </a>
          ))}
        </nav>
        {equipe && (
          <div className="lateral-links">
            <a href="/tv" target="_blank" rel="noreferrer"><Tv size={16} /><span>Modo TV</span></a>
            <a href="/" target="_blank" rel="noreferrer"><ExternalLink size={16} /><span>Link público</span></a>
          </div>
        )}
        <div className="lateral-usuario">
          <div className="avatar" aria-hidden="true">{(nomeUsuario || '?').trim().charAt(0).toUpperCase()}</div>
          <div className="usuario-dados">
            <strong>{nomeUsuario}</strong>
            <span>{subtitulo}</span>
          </div>
          <button className="icone-botao" onClick={() => supabase.auth.signOut()} aria-label="Sair" title="Sair"><LogOut size={18} /></button>
        </div>
      </aside>
      <div className="fundo-menu so-celular" onClick={() => setMenuAberto(false)} />

      <div className="conteudo">
        <header className="barra-celular so-celular">
          <button className="icone-botao" onClick={() => setMenuAberto(true)} aria-label="Abrir menu"><Menu size={22} /></button>
          <Logo className="logo-pequeno" />
          <span />
        </header>
        <main>{pagina}</main>
      </div>
    </div>
  );
}

function EspelhoSomenteLeitura() {
  const esp = useEspelho();
  return (
    <section className="secao larga">
      <div className="secao-topo">
        <div><h2>Espelho de unidades</h2><p className="sub">Disponibilidade atualizada em tempo real.</p></div>
        <StatusConexao conectado={esp.conectado} />
      </div>
      <div className="cartao espelho-cartao">
        <Resumo unidades={esp.unidades} />
        <Predio unidades={esp.unidades} recentes={esp.recentes} />
      </div>
    </section>
  );
}

function EspelhoEquipe({ perfil }: { perfil: Perfil }) {
  const esp = useEspelho();
  const { confirmar, avisar } = useDialogos();
  const [selecionada, setSelecionada] = useState<Unidade | null>(null);
  const [historico, setHistorico] = useState<Registro[]>([]);

  const carregarHistorico = useCallback(async () => {
    const { data } = await supabase.from('historico')
      .select('id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em')
      .order('criado_em', { ascending: false }).limit(20);
    setHistorico((data as Registro[]) ?? []);
  }, []);
  const ultimaMudanca = Math.max(0, ...Object.values(esp.recentes));
  useEffect(() => { carregarHistorico(); }, [carregarHistorico, ultimaMudanca]);

  const atual = selecionada ? esp.unidades.find((u) => u.id === selecionada.id) ?? selecionada : null;

  const alternarPublico = async () => {
    if (!esp.config) return;
    const ativar = !esp.config.publico_ativo;
    if (!ativar && !(await confirmar({ titulo: 'Tirar o link público do ar?', texto: 'Quem estiver com o link aberto deixa de ver o espelho. A equipe e as imobiliárias logadas continuam vendo.', confirmar: 'Tirar do ar', perigo: true }))) return;
    const { error } = await supabase.rpc('definir_publico', { p_ativo: ativar });
    if (error) avisar('Não foi possível alterar o link público. Tente novamente.', 'erro');
    else avisar(ativar ? 'Link público no ar.' : 'Link público fora do ar.');
    esp.recarregar();
  };

  return (
    <section className="secao larga">
      <div className="secao-topo">
        <div><h2>Espelho de unidades</h2><p className="sub">Toque em uma unidade para alterar o status.</p></div>
        <StatusConexao conectado={esp.conectado} />
      </div>
      <div className="painel-corpo">
        <div className="cartao espelho-cartao">
          <Resumo unidades={esp.unidades} />
          <Predio unidades={esp.unidades} recentes={esp.recentes} aoSelecionar={setSelecionada} />
        </div>

        <aside className="painel-lateral">
          {perfil.papel === 'admin' && esp.config && (
            <div className="cartao">
              <h3>Link público</h3>
              <p className="sub">{esp.config.publico_ativo ? 'No ar. Qualquer pessoa com o link vê o espelho.' : 'Fora do ar. Só a equipe e as imobiliárias logadas veem o espelho.'}</p>
              <button className="botao" onClick={alternarPublico}>{esp.config.publico_ativo ? 'Tirar do ar' : 'Colocar no ar'}</button>
            </div>
          )}
          <div className="cartao">
            <h3>Últimas alterações</h3>
            {historico.length === 0 ? <p className="vazio">Nenhuma alteração ainda.</p> : (
              <ol className="historico">
                {historico.map((h) => (
                  <li key={h.id}>
                    <span><strong>{h.numero}</strong> {h.status_anterior ? rotuloStatus(h.status_anterior).toLowerCase() : ''} para{' '}
                      <span className={`etiqueta s-${h.status_novo}`}>{rotuloStatus(h.status_novo).toLowerCase()}</span></span>
                    {h.motivo && <span className="motivo">“{h.motivo}”</span>}
                    <span className="quem">{h.usuario_email}, {formatarDataHora(h.criado_em)}</span>
                  </li>
                ))}
              </ol>
            )}
          </div>
        </aside>
      </div>

      {atual && (
        <DialogoUnidade
          unidade={atual}
          aoFechar={() => setSelecionada(null)}
          aoSalvar={(u) => { esp.atualizarLocal(u); setSelecionada(null); carregarHistorico(); avisar(`Unidade ${u.numero}: ${rotuloStatus(u.status).toLowerCase()}.`); }}
          aoConflito={() => esp.recarregar()}
        />
      )}
    </section>
  );
}

const EM_NEGOCIACAO: Status[] = ['reservada', 'proposta', 'contrato', 'vendida'];
const EXIGE_MOTIVO = (de: Status, para: Status) =>
  EM_NEGOCIACAO.includes(de) && (para === 'disponivel' || para === 'bloqueada' || para === 'permutante');

interface Negociacao {
  imobiliaria: string | null; corretor: string | null; cliente: string | null;
  valor_venda: number | null; pv_aprovado: number | null;
  pasta_id: string | null; pastas: { codigo: string; codigo_aprovacao: string | null } | null;
}

interface PastaLivre {
  id: string; codigo: string; codigo_aprovacao: string | null; comprador_nome: string;
  criado_por: string | null; imobiliarias: { nome: string } | null; unidades_numeros: string | null;
}

const ERROS: Record<string, string> = {
  CONFLITO: 'Outra pessoa alterou esta unidade agora há pouco. Feche, confira o status atual e tente de novo.',
  MOTIVO_OBRIGATORIO: 'Informe o motivo para desfazer a negociação.',
  PASTA_OBRIGATORIA: 'Escolha a pasta do cliente. Só pastas com documentação aprovada podem reservar.',
  PASTA_NAO_APROVADA: 'Esta pasta ainda não está com a documentação aprovada.',
  PASTA_JA_TEM_UNIDADE: 'Esta pasta já está com outra unidade. Libere a outra unidade antes.',
  UNIDADE_COM_OUTRA_PASTA: 'Esta unidade já está com outra pasta. Libere a unidade antes de trocar o cliente.',
  DADOS_PROPOSTA_OBRIGATORIOS: 'Preencha o valor da venda e o PV aprovado.',
  VALOR_INVALIDO: 'O valor da venda precisa ser maior que zero.',
  PV_INVALIDO: 'O PV aprovado não pode ser negativo.',
  SEM_PERMISSAO: 'Seu usuário não tem permissão para alterar unidades.',
};

const formatarPV = (v: number | null | undefined) =>
  v == null ? '—' : `${v.toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%`;

function DialogoUnidade({ unidade, aoFechar, aoSalvar, aoConflito }: {
  unidade: Unidade; aoFechar: () => void; aoSalvar: (u: Unidade) => void; aoConflito: () => void;
}) {
  const [novo, setNovo] = useState<Status | null>(null);
  const [motivo, setMotivo] = useState('');
  const [pastaId, setPastaId] = useState('');
  const [pastasLivres, setPastasLivres] = useState<PastaLivre[] | null>(null);
  const [valor, setValor] = useState('');
  const [pv, setPv] = useState('');
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);
  const [registros, setRegistros] = useState<Registro[]>([]);
  const [neg, setNeg] = useState<Negociacao | null>(null);
  const [versaoAberta] = useState(unidade.versao);

  useEffect(() => {
    supabase.from('historico')
      .select('id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em, detalhes')
      .eq('unidade_id', unidade.id).order('criado_em', { ascending: false }).limit(10)
      .then(({ data }) => setRegistros((data as Registro[]) ?? []));
    supabase.from('negociacoes')
      .select('imobiliaria, corretor, cliente, valor_venda, pv_aprovado, pasta_id, pastas(codigo, codigo_aprovacao)')
      .eq('unidade_id', unidade.id).eq('ativa', true).maybeSingle()
      .then(({ data }) => {
        const n = (data as unknown as Negociacao) ?? null;
        setNeg(n);
        if (n) {
          setValor(n.valor_venda != null ? n.valor_venda.toLocaleString('pt-BR', { minimumFractionDigits: 2 }) : '');
          setPv(n.pv_aprovado != null ? n.pv_aprovado.toLocaleString('pt-BR') : '');
        }
      });
  }, [unidade.id, unidade.versao]);

  // pastas com documentação aprovada (um cliente pode comprar mais de uma unidade)
  useEffect(() => {
    supabase.from('pastas')
      .select('id, codigo, codigo_aprovacao, comprador_nome, criado_por, imobiliarias(nome), unidades_numeros')
      .eq('status', 'aprovada').order('comprador_nome')
      .then(({ data }) => setPastasLivres((data as unknown as PastaLivre[]) ?? []));
  }, []);

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && aoFechar();
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [aoFechar]);

  const mudouPorOutro = unidade.versao !== versaoAberta;
  const precisaMotivo = novo ? EXIGE_MOTIVO(unidade.status, novo) : false;
  // em negociação, a unidade precisa estar ligada a uma pasta aprovada
  const pedePasta = novo != null && EM_NEGOCIACAO.includes(novo) && !neg?.pasta_id;
  const pedeProposta = novo === 'proposta';
  const pastaEscolhida = pastasLivres?.find((p) => p.id === pastaId);

  const salvar = async () => {
    if (!novo) return;
    const valorNum = lerNumero(valor);
    const pvNum = lerNumero(pv);
    if (precisaMotivo && !motivo.trim()) { setErro(ERROS.MOTIVO_OBRIGATORIO); return; }
    if (pedePasta && !pastaId) { setErro(ERROS.PASTA_OBRIGATORIA); return; }
    if (pedeProposta) {
      if (valorNum == null || pvNum == null) { setErro(ERROS.DADOS_PROPOSTA_OBRIGATORIOS); return; }
      if (valorNum <= 0) { setErro(ERROS.VALOR_INVALIDO); return; }
      if (pvNum < 0) { setErro(ERROS.PV_INVALIDO); return; }
    }
    setSalvando(true); setErro('');
    const { data, error } = await supabase.rpc('alterar_status', {
      p_unidade_id: unidade.id, p_status: novo, p_versao: versaoAberta, p_motivo: motivo.trim() || null,
      p_valor: pedeProposta ? valorNum : null,
      p_pv: pedeProposta ? pvNum : null,
      p_pasta: pedePasta ? pastaId : null,
    });
    setSalvando(false);
    if (error) {
      const chave = Object.keys(ERROS).find((k) => error.message.includes(k));
      setErro(chave ? ERROS[chave] : 'Não foi possível salvar. Verifique a internet e tente novamente.');
      if (chave === 'CONFLITO') aoConflito();
      return;
    }
    aoSalvar(data as Unidade);
  };

  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <div className="dialogo" role="dialog" aria-modal="true" aria-labelledby="titulo-unidade" onClick={(e) => e.stopPropagation()}>
        <header className="dialogo-topo">
          <h2 id="titulo-unidade">Unidade {unidade.numero}</h2>
          <button className="fechar" onClick={aoFechar} aria-label="Fechar">×</button>
        </header>
        <dl className="ficha">
          <div><dt>Andar</dt><dd>{unidade.andar}º</dd></div>
          <div><dt>Área privativa</dt><dd>{formatarArea(unidade.area_privativa)}</dd></div>
          <div><dt>Tipologia</dt><dd>{unidade.tipologia || '—'}</dd></div>
          <div><dt>Status atual</dt><dd><span className={`etiqueta s-${unidade.status}`}>{rotuloStatus(unidade.status)}</span></dd></div>
        </dl>

        {neg && EM_NEGOCIACAO.includes(unidade.status) && (
          <dl className="ficha negociacao">
            <div><dt>Imobiliária</dt><dd>{neg.imobiliaria || '—'}</dd></div>
            <div><dt>Corretor</dt><dd>{neg.corretor || '—'}</dd></div>
            <div><dt>Cliente</dt><dd>{neg.cliente || '—'}</dd></div>
            <div><dt>Pasta</dt><dd>{neg.pastas ? (neg.pastas.codigo_aprovacao ?? neg.pastas.codigo) : 'Sem pasta'}</dd></div>
            <div><dt>Valor da venda</dt><dd>{formatarReais(neg.valor_venda)}</dd></div>
            <div><dt>PV aprovado</dt><dd>{formatarPV(neg.pv_aprovado)}</dd></div>
          </dl>
        )}

        {mudouPorOutro && <p className="erro" role="alert">Esta unidade acabou de ser alterada por outra pessoa. Feche e abra de novo antes de mudar.</p>}

        <fieldset className="opcoes" disabled={mudouPorOutro || salvando}>
          <legend>Novo status</legend>
          {STATUS.map((s) => (
            <button key={s.valor} type="button"
              className={`opcao s-${s.valor}${novo === s.valor ? ' escolhida' : ''}`}
              disabled={s.valor === unidade.status}
              aria-pressed={novo === s.valor}
              onClick={() => { setNovo(s.valor); setErro(''); }}>
              {s.rotulo}
            </button>
          ))}
        </fieldset>

        {pedePasta && (
          <div className="campos">
            <label className="largo">Pasta do cliente (documentação aprovada)
              <select value={pastaId} onChange={(e) => { setPastaId(e.target.value); setErro(''); }} disabled={!pastasLivres?.length}>
                <option value="">{pastasLivres == null ? 'Carregando…' : pastasLivres.length ? 'Escolha a pasta' : 'Nenhuma pasta disponível'}</option>
                {pastasLivres?.map((p) => (
                  <option key={p.id} value={p.id}>
                    {(p.codigo_aprovacao ?? p.codigo)} · {p.comprador_nome}{p.imobiliarias ? ` · ${p.imobiliarias.nome}` : ''}{p.unidades_numeros ? ` · já com ${p.unidades_numeros}` : ''}
                  </option>
                ))}
              </select>
            </label>
            {pastasLivres?.length === 0 && (
              <p className="dica largo">Nenhuma pasta com documentação aprovada. A reserva só pode ser feita depois que a documentação for aprovada.</p>
            )}
            {pastaEscolhida && (
              <p className="dica largo">
                Cliente {pastaEscolhida.comprador_nome}
                {pastaEscolhida.imobiliarias ? `, ${pastaEscolhida.imobiliarias.nome}` : ''}
                {pastaEscolhida.criado_por ? `, corretor ${pastaEscolhida.criado_por}` : ''}.
                {pastaEscolhida.unidades_numeros ? ` Esta pasta já tem ${pastaEscolhida.unidades_numeros}; esta unidade vira um novo card no funil.` : ' A unidade aparece como card no funil.'}
              </p>
            )}
          </div>
        )}

        {pedeProposta && (
          <div className="campos">
            <label>Valor da venda (R$)
              <input inputMode="decimal" value={valor} onChange={(e) => setValor(e.target.value)} placeholder="Ex.: 289.900,00"
                onBlur={() => { const n = lerNumero(valor); if (n != null) setValor(n.toLocaleString('pt-BR', { minimumFractionDigits: 2 })); }} />
            </label>
            <label>PV aprovado (%)
              <input inputMode="decimal" value={pv} onChange={(e) => setPv(e.target.value)} placeholder="Ex.: 85" />
            </label>
          </div>
        )}

        {novo && (precisaMotivo || (!pedePasta && !pedeProposta)) && (
          <label className="campo-motivo">
            {precisaMotivo ? 'Motivo (obrigatório)' : 'Observação (opcional)'}
            <textarea rows={2} value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={300}
              placeholder={precisaMotivo ? 'Ex.: cliente desistiu da compra' : ''} />
          </label>
        )}

        {erro && <p className="erro" role="alert">{erro}</p>}

        <div className="dialogo-acoes">
          <button className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal" disabled={!novo || salvando || mudouPorOutro} onClick={salvar}>
            {salvando ? 'Salvando…' : novo ? `Marcar como ${rotuloStatus(novo).toLowerCase()}` : 'Escolha o novo status'}
          </button>
        </div>

        {registros.length > 0 && (
          <div className="dialogo-historico">
            <h3>Histórico desta unidade</h3>
            <ol className="historico">
              {registros.map((h) => (
                <li key={h.id}>
                  {h.status_anterior ? rotuloStatus(h.status_anterior) : ''} para{' '}
                  <span className={`etiqueta s-${h.status_novo}`}>{rotuloStatus(h.status_novo).toLowerCase()}</span>
                  {h.detalhes && <span className="motivo">{resumoDetalhes(h.detalhes)}</span>}
                  {h.motivo && <span className="motivo">“{h.motivo}”</span>}
                  <span className="quem">{h.usuario_email}, {formatarDataHora(h.criado_em)}</span>
                </li>
              ))}
            </ol>
          </div>
        )}
      </div>
    </div>
  );
}

function resumoDetalhes(d: Record<string, unknown>) {
  const partes: string[] = [];
  if (d.cliente) partes.push(`Cliente: ${d.cliente}`);
  if (d.imobiliaria) partes.push(`Imobiliária: ${d.imobiliaria}`);
  if (d.corretor) partes.push(`Corretor: ${d.corretor}`);
  if (d.valor_venda != null) partes.push(`Valor: ${formatarReais(Number(d.valor_venda))}`);
  if (d.pv_aprovado != null) partes.push(`PV: ${formatarPV(Number(d.pv_aprovado))}`);
  return partes.join('; ');
}
