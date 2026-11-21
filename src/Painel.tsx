import { Leads, DetalheLead } from './Leads';
import { Manual } from './manual/Manual';
import type { ModuloManual, PapelManual } from './manual/conteudo';
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import {
  Home, LayoutGrid, FolderOpen, Building2, Users, Settings, LogOut, ExternalLink, Tv, Menu, X, Kanban, Handshake, ClipboardCheck, Library, GraduationCap,
  FileSignature, BarChart3, ListOrdered, Table2, ArrowLeft, ScrollText, Megaphone, BookOpen,
} from 'lucide-react';
import {
  supabase, configurado, useEspelho, STATUS, rotuloStatus, formatarArea, formatarDataHora, formatarReais, lerNumero,
  type Unidade, type Status,
} from './dados';
import { Predio, Resumo } from './Predio';
import { Aviso, StatusConexao, useTitulo } from './Publico';
import { ListaPastas, DetalhePasta } from './Pastas';
import { Imobiliarias, Corretores } from './Imobiliarias';
import { Paineis } from './Paineis';
import { TabelaVendas } from './TabelaVendas';
import { useEmpreendimentos } from './Empreendimentos';
import { Vitrine } from './Vitrine';
import { entrarNoEmpreendimento, irParaVitrine, semBase, slugAba } from './rotaEmp';
import { EscolhaUnidades, useSituacaoFila } from './Fila';
import { Empreendimento } from './Empreendimento';
import { Funil } from './Funil';
import { Rodadas, DetalheRodada } from './Rodadas';
import { MeetingCorretor, MeetingPainel } from './Meeting';
import { Treinamentos } from './Treinamentos';
import { Portal } from './Portal';
import { ListaPropostas, PaginaProposta } from './proposta/Propostas';
import { ListaContratos, PaginaContrato } from './contrato/Contratos';
import { useRota, ir, CAMPOS_PERFIL, formatarCPF, formatarCNPJ, cpfValido, cnpjValido, nomeCompleto, ERROS_CADASTRO, type Perfil } from './util';
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
  const [recuperando, setRecuperando] = useState(() => semBase(location.pathname) === '/painel/nova-senha' || location.hash.includes('type=recovery'));
  const [imobDados, setImobDados] = useState<{ cnpj: string | null; creci_pj: string | null } | null | undefined>(undefined);

  useEffect(() => {
    if (!configurado) { setSessao(null); return; }
    supabase.auth.getSession().then(({ data }) => setSessao(data.session));
    const { data } = supabase.auth.onAuthStateChange((e, s) => { setSessao(s); if (e === 'PASSWORD_RECOVERY') setRecuperando(true); });
    return () => data.subscription.unsubscribe();
  }, []);

  const idUsuario = sessao?.user.id;
  useEffect(() => {
    if (!idUsuario) { setPerfil(sessao === null ? null : undefined); return; }
    (async () => {
      const r = await supabase.from('perfis').select(CAMPOS_PERFIL).eq('user_id', idUsuario).maybeSingle();
      if (!r.error) { setPerfil((r.data as Perfil) ?? null); return; }
      // banco ainda sem a migração 023: entra sem pedir os dados novos
      const v = await supabase.from('perfis').select('user_id, email, nome, papel, imobiliaria_id, trocar_senha').eq('user_id', idUsuario).maybeSingle();
      setPerfil(v.data ? ({ ...(v.data as Perfil), cpf: '-', creci: '-', nome: (v.data as Perfil).nome || '- -' }) : null);
    })();
  }, [idUsuario, recarga]); // eslint-disable-line react-hooks/exhaustive-deps

  // a imobiliária completa também o CNPJ e o CRECI PJ
  const idImob = perfil?.papel === 'imobiliaria' ? perfil.imobiliaria_id : null;
  useEffect(() => {
    if (!idImob) { setImobDados(null); return; }
    supabase.from('imobiliarias').select('cnpj, creci_pj').eq('id', idImob).maybeSingle()
      .then(({ data, error }) => setImobDados(error ? { cnpj: '-', creci_pj: '-' } : ((data as { cnpj: string | null; creci_pj: string | null }) ?? null)));
  }, [idImob, recarga]);

  if (!configurado) return <Aviso texto="O sistema ainda não foi conectado ao banco de dados." />;
  if (sessao === undefined) return <Aviso texto="Carregando…" />;
  if (!sessao) return <Login />;
  if (recuperando) {
    return <TrocarSenha recuperacao aoTrocar={() => { setRecuperando(false); history.replaceState(null, '', '/painel'); setRecarga((n) => n + 1); }} />;
  }
  if (perfil === undefined) return <Aviso texto="Carregando…" />;
  if (!perfil) return <SemAcesso email={sessao.user.email ?? ''} userId={sessao.user.id} />;
  if (perfil.trocar_senha) return <TrocarSenha aoTrocar={() => setRecarga((n) => n + 1)} />;
  if (perfil.papel === 'imobiliaria' && imobDados === undefined) return <Aviso texto="Carregando…" />;
  const faltaPessoa = (perfil.papel === 'imobiliaria' || perfil.papel === 'corretor')
    && (!nomeCompleto(perfil.nome) || !perfil.cpf || !perfil.creci);
  const faltaEmpresa = perfil.papel === 'imobiliaria' && (!imobDados?.cnpj || !imobDados?.creci_pj);
  if (faltaPessoa || faltaEmpresa) {
    return <CompletarCadastro perfil={perfil} imob={imobDados ?? null} aoSalvar={() => setRecarga((n) => n + 1)} />;
  }
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
  const [modo, setModo] = useState<'entrar' | 'esqueci' | 'enviado'>('entrar');
  const { marca } = useMarca();

  const entrar = async (e: FormEvent) => {
    e.preventDefault();
    setEnviando(true); setErro('');
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
    if (error) { setErro('E-mail ou senha incorretos.'); setEnviando(false); return; }
    // ao entrar, sempre começa pela tela de Início
    if (semBase(location.pathname) !== '/painel') ir('/painel');
  };

  const enviarLink = async (e: FormEvent) => {
    e.preventDefault();
    setEnviando(true); setErro('');
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim().toLowerCase(), { redirectTo: `${location.origin}/painel/nova-senha` });
    setEnviando(false);
    // por segurança, a mesma mensagem aparece exista ou não o e-mail; só falhas de envio são mostradas
    if (error && /rate|limit|seconds/i.test(error.message)) { setErro('Muitos pedidos seguidos. Espere alguns minutos e tente de novo.'); return; }
    if (error && !/not found|user/i.test(error.message)) { setErro('Não foi possível enviar o e-mail agora. Tente de novo em alguns minutos.'); return; }
    setModo('enviado');
  };

  if (modo === 'enviado') {
    return (
      <TelaAcesso>
        <div className="login">
          <h1>Confira seu e-mail</h1>
          <p className="dica">Se <b>{email.trim().toLowerCase()}</b> tiver acesso ao painel, você vai receber em instantes um link para criar uma nova senha. O link vale por 1 hora.</p>
          <p className="dica">Não chegou? Veja a caixa de spam ou promoções.</p>
          <button className="botao largo" onClick={() => setModo('entrar')}>Voltar para o login</button>
        </div>
      </TelaAcesso>
    );
  }

  if (modo === 'esqueci') {
    return (
      <TelaAcesso>
        <form className="login" onSubmit={enviarLink}>
          <h1>Esqueci minha senha</h1>
          <p className="dica">Informe o e-mail do seu login. Enviaremos um link para você criar uma nova senha.</p>
          <label>E-mail<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required autoFocus /></label>
          {erro && <p className="erro" role="alert">{erro}</p>}
          <button className="botao principal largo" disabled={enviando}>{enviando ? 'Enviando…' : 'Enviar link'}</button>
          <button type="button" className="botao largo" onClick={() => { setModo('entrar'); setErro(''); }}>Voltar</button>
        </form>
      </TelaAcesso>
    );
  }

  return (
    <TelaAcesso>
      <form className="login" onSubmit={entrar}>
        <h1>Acessar o Gestor Launch Machine</h1>
        <p className="dica">Acesso para a equipe de vendas, imobiliárias e corretores.</p>
        <label>E-mail<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        <label>Senha<input type="password" autoComplete="current-password" value={senha} onChange={(e) => setSenha(e.target.value)} required /></label>
        {erro && <p className="erro" role="alert">{erro}</p>}
        <button className="botao principal largo" disabled={enviando}>{enviando ? 'Entrando…' : 'Entrar'}</button>
        <button type="button" className="link-acao esqueci" onClick={() => { setModo('esqueci'); setErro(''); }}>Esqueci minha senha</button>
        {marca.modulo_cadastro !== false && <p className="dica cadastro-link">Sua imobiliária ainda não tem acesso? <a href="/cadastro">Cadastre a imobiliária</a></p>}
      </form>
    </TelaAcesso>
  );
}

/** Imobiliária e corretor completam os dados usados no contrato de intermediação. */
function CompletarCadastro({ perfil, imob, aoSalvar }: { perfil: Perfil; imob: { cnpj: string | null; creci_pj: string | null } | null; aoSalvar: () => void }) {
  const gestor = perfil.papel === 'imobiliaria';
  const [nome, setNome] = useState(perfil.nome ?? '');
  const [cpf, setCpf] = useState(formatarCPF(perfil.cpf));
  const [creci, setCreci] = useState(perfil.creci ?? '');
  const [cnpj, setCnpj] = useState(formatarCNPJ(imob?.cnpj));
  const [creciPj, setCreciPj] = useState(imob?.creci_pj ?? '');
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);
  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (!nomeCompleto(nome)) { setErro(ERROS_CADASTRO.NOME_COMPLETO_OBRIGATORIO); return; }
    if (!cpfValido(cpf)) { setErro(ERROS_CADASTRO.CPF_INVALIDO); return; }
    if (!creci.trim()) { setErro(ERROS_CADASTRO.CRECI_OBRIGATORIO); return; }
    if (gestor && !cnpjValido(cnpj)) { setErro(ERROS_CADASTRO.CNPJ_INVALIDO); return; }
    if (gestor && !creciPj.trim()) { setErro(ERROS_CADASTRO.CRECI_PJ_OBRIGATORIO); return; }
    setSalvando(true);
    const { error } = await supabase.rpc('completar_cadastro', {
      p_nome: nome, p_cpf: cpf, p_creci: creci, p_cnpj: gestor ? cnpj : null, p_creci_pj: gestor ? creciPj : null,
    });
    setSalvando(false);
    if (error) { setErro(ERROS_CADASTRO[error.message] ?? 'Não foi possível salvar. Tente novamente.'); return; }
    aoSalvar();
  };
  return (
    <TelaAcesso>
      <form className="login" onSubmit={salvar}>
        <h1>Complete seu cadastro</h1>
        <p className="dica">Estes dados entram nos documentos da venda, como o contrato de intermediação. Preencha uma única vez.</p>
        <label>Nome completo<input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={120} required autoComplete="name" /></label>
        <label>CPF<input value={cpf} onChange={(e) => setCpf(formatarCPF(e.target.value))} inputMode="numeric" required /></label>
        <label>CRECI PF<input value={creci} onChange={(e) => setCreci(e.target.value)} maxLength={30} required /></label>
        {gestor && (
          <>
            <label>CNPJ da imobiliária<input value={cnpj} onChange={(e) => setCnpj(formatarCNPJ(e.target.value))} inputMode="numeric" required /></label>
            <label>CRECI PJ da imobiliária<input value={creciPj} onChange={(e) => setCreciPj(e.target.value)} maxLength={30} required /></label>
          </>
        )}
        {!gestor && <p className="dica">O CNPJ e o CRECI PJ usados são os da sua imobiliária.</p>}
        {erro && <p className="erro" role="alert">{erro}</p>}
        <button className="botao principal largo" disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar e continuar'}</button>
        <button type="button" className="botao largo" onClick={() => supabase.auth.signOut()}>Sair</button>
      </form>
    </TelaAcesso>
  );
}

function TrocarSenha({ aoTrocar, recuperacao }: { aoTrocar: () => void; recuperacao?: boolean }) {
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
        <h1>{recuperacao ? 'Crie uma nova senha' : 'Crie sua senha'}</h1>
        <p className="dica">{recuperacao ? 'Escolha uma senha nova, com pelo menos 8 caracteres. Ela substitui a anterior.' : 'Você entrou com uma senha provisória. Crie uma senha própria, com pelo menos 8 caracteres.'}</p>
        <label>Nova senha<input type="password" autoComplete="new-password" value={senha} onChange={(e) => setSenha(e.target.value)} required /></label>
        <label>Repita a nova senha<input type="password" autoComplete="new-password" value={confirma} onChange={(e) => setConfirma(e.target.value)} required /></label>
        {erro && <p className="erro" role="alert">{erro}</p>}
        <button className="botao principal largo" disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar senha'}</button>
        <button type="button" className="botao largo" onClick={() => supabase.auth.signOut()}>Sair</button>
      </form>
    </TelaAcesso>
  );
}

const PAPEL: Record<Perfil['papel'], string> = { admin: 'Administrador', vendas: 'Sec. Vendas', imobiliaria: 'Imobiliária', corretor: 'Corretor', recepcao: 'Recepcionista' };

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
  const recepcao = perfil.papel === 'recepcao';
  const pastasAtivas = marca.modulo_pastas;
  const funilAtivo = pastasAtivas && marca.modulo_funil !== false;
  const portalAtivo = marca.modulo_portal !== false;
  const rodadasAtivas = marca.modulo_rodadas !== false;
  // Propostas: coluna só existe depois do 035; desligado, só o administrador vê (para testar)
  const propostasExiste = 'modulo_propostas' in marca;
  const propostasLigadas = propostasExiste && marca.modulo_propostas === true && pastasAtivas;
  const propostasVisiveis = equipe ? (propostasLigadas || (admin && propostasExiste)) : propostasLigadas;
  const treinosAtivos = (marca as { modulo_treinamentos?: boolean }).modulo_treinamentos !== false;
  const meetingAtivo = marca.modulo_meeting !== false;
  const espelhoParceiros = marca.modulo_espelho_parceiros !== false;
  const tvAtiva = marca.modulo_tv !== false;
  // Leads: desligado, só o administrador vê (para configurar e testar)
  const leadsLigados = (marca as { modulo_leads?: boolean }).modulo_leads === true;
  const leadsVisiveis = leadsLigados || admin;

  useEffect(() => {
    if (!equipe && !recepcao) supabase.from('imobiliarias').select('nome').maybeSingle()
      .then(({ data }) => setImob((data as { nome: string } | null)?.nome ?? ''));
  }, [equipe, recepcao]);
  useEffect(() => setMenuAberto(false), [rota]);
  useTitulo(marca.nome_empreendimento ? `Painel, ${marca.nome_empreendimento}` : undefined);

  const sair = useCallback(() => {
    supabase.auth.signOut();
    avisar('Sessão encerrada por inatividade.');
  }, [avisar]);
  useSaidaPorInatividade(MINUTOS_INATIVIDADE, sair);

  const { situacao: fila } = useSituacaoFila();
  const emps = useEmpreendimentos();
  // o tempo real usa o empreendimento guardado no perfil: acompanha a aba em uso
  const idEmpAba = slugAba ? emps.lista?.find((e) => e.slug === slugAba)?.id : undefined;
  useEffect(() => {
    if (!idEmpAba) return;
    const sincronizar = () => { void supabase.rpc('escolher_empreendimento', { p_emp: idEmpAba }); };
    sincronizar();
    window.addEventListener('focus', sincronizar);
    return () => window.removeEventListener('focus', sincronizar);
  }, [idEmpAba]);
  // Módulos visíveis por perfil (o manual usa a mesma regra do menu)
  const modulosDe = useCallback((p: PapelManual): Set<ModuloManual> => {
    const m = new Set<ModuloManual>();
    const add = (cond: boolean, ...k: ModuloManual[]) => { if (cond) k.forEach((x) => m.add(x)); };
    if (p === 'recepcao') { add(meetingAtivo, 'meeting'); return m; }
    if (p === 'admin' || p === 'vendas') {
      add(true, 'inicio', 'espelho');
      add(tvAtiva, 'tv');
      add(pastasAtivas, 'pastas');
      add(funilAtivo, 'funil');
      add(leadsLigados || p === 'admin', 'leads');
      add(propostasLigadas || (p === 'admin' && propostasExiste), 'propostas', 'contratos');
      add(portalAtivo, 'portal'); add(rodadasAtivas, 'rodadas'); add(treinosAtivos, 'treinamentos'); add(meetingAtivo, 'meeting');
      add(p === 'admin', 'imobiliarias', 'empreendimento');
      add(true, 'tabela'); add(pastasAtivas, 'escolha');
      return m;
    }
    add(leadsLigados, 'leads'); add(pastasAtivas, 'pastas'); add(funilAtivo, 'funil'); add(propostasLigadas, 'propostas');
    add(portalAtivo, 'portal'); add(rodadasAtivas, 'rodadas'); add(treinosAtivos, 'treinamentos'); add(espelhoParceiros, 'espelho');
    add(p === 'imobiliaria', 'corretores'); add(true, 'tabela'); add(meetingAtivo, 'meeting');
    return m;
  }, [meetingAtivo, tvAtiva, pastasAtivas, funilAtivo, leadsLigados, propostasLigadas, propostasExiste, portalAtivo, rodadasAtivas, treinosAtivos, espelhoParceiros]);

  type Item = { c: string; r: string; i: ReactNode };
  const menu: Item[] = recepcao
    ? (meetingAtivo ? [{ c: '/painel/meeting', r: 'Meeting', i: <ClipboardCheck size={18} /> }] : [])
    : equipe
    ? [
      { c: '/painel', r: 'Painéis', i: <BarChart3 size={18} /> },
      { c: '/painel/espelho', r: 'Espelho', i: <LayoutGrid size={18} /> },
      ...(pastasAtivas ? [{ c: '/painel/pastas', r: 'Pastas', i: <FolderOpen size={18} /> }] : []),
      ...(leadsVisiveis ? [{ c: '/painel/leads', r: 'Leads', i: <Megaphone size={18} /> }] : []),
      ...(funilAtivo ? [{ c: '/painel/funil', r: 'Funil de vendas', i: <Kanban size={18} /> }] : []),
      ...(propostasVisiveis ? [{ c: '/painel/propostas', r: 'Propostas', i: <FileSignature size={18} /> }] : []),
      ...(propostasVisiveis ? [{ c: '/painel/contratos', r: 'Contratos', i: <ScrollText size={18} /> }] : []),
      { c: '/painel/tabela', r: 'Tabela de vendas', i: <Table2 size={18} /> },
      ...(pastasAtivas ? [{ c: '/painel/escolha', r: 'Escolha de unidades', i: <ListOrdered size={18} /> }] : []),
      ...(portalAtivo ? [{ c: '/painel/portal', r: 'Portal do Corretor', i: <Library size={18} /> }] : []),
      ...(rodadasAtivas ? [{ c: '/painel/rodadas', r: 'Rodadas de negócios', i: <Handshake size={18} /> }] : []),
      ...(treinosAtivos ? [{ c: '/painel/treinamentos', r: 'Treinamentos', i: <GraduationCap size={18} /> }] : []),
      ...(meetingAtivo ? [{ c: '/painel/meeting', r: 'Meeting', i: <ClipboardCheck size={18} /> }] : []),
      ...(admin ? [
        { c: '/painel/imobiliarias', r: 'Imobiliárias e logins', i: <Building2 size={18} /> },
        { c: '/painel/empreendimento', r: 'Empreendimentos', i: <Settings size={18} /> },
      ] : []),
    ]
    : [
      ...(leadsLigados ? [{ c: '/painel/leads', r: 'Leads', i: <Megaphone size={18} /> }] : []),
      ...(pastasAtivas ? [{ c: '/painel/pastas', r: 'Pastas', i: <FolderOpen size={18} /> }] : []),
      ...(fila?.ativa ? [{ c: '/painel/escolha', r: 'Escolha de unidades', i: <ListOrdered size={18} /> }] : []),
      ...(funilAtivo ? [{ c: '/painel/funil', r: 'Funil de vendas', i: <Kanban size={18} /> }] : []),
      ...(propostasVisiveis ? [{ c: '/painel/propostas', r: 'Propostas', i: <FileSignature size={18} /> }] : []),
      ...(portalAtivo ? [{ c: '/painel/portal', r: 'Portal do Corretor', i: <Library size={18} /> }] : []),
      ...(rodadasAtivas ? [{ c: '/painel/rodadas', r: 'Rodadas de negócios', i: <Handshake size={18} /> }] : []),
      ...(treinosAtivos ? [{ c: '/painel/treinamentos', r: 'Treinamentos', i: <GraduationCap size={18} /> }] : []),
      { c: '/painel/tabela', r: 'Tabela de vendas', i: <Table2 size={18} /> },
      ...(meetingAtivo ? [{ c: '/painel/meeting', r: 'Meeting', i: <ClipboardCheck size={18} /> }] : []),
      ...(gestor ? [{ c: '/painel/corretores', r: 'Corretores', i: <Users size={18} /> }] : []),
      ...(espelhoParceiros ? [{ c: '/painel/espelho', r: 'Espelho', i: <LayoutGrid size={18} /> }] : []),
    ];
  if (!menu.length) menu.push({ c: '/painel/sem-modulos', r: 'Início', i: <Home size={18} /> });
  menu.push({ c: '/painel/manual', r: 'Manual', i: <BookOpen size={18} /> });
  const inicial = menu[0].c;
  const atual = rota === '/painel' ? inicial : rota;
  const ativo = (c: string) => (c === '/painel' ? atual === '/painel' : atual.startsWith(c));

  let pagina: ReactNode;
  const idPasta = atual.match(/^\/painel\/pastas\/([^/]+)$/)?.[1];
  const idRodada = atual.match(/^\/painel\/rodadas\/([^/]+)$/)?.[1];
  const idProposta = atual.match(/^\/painel\/propostas\/([^/]+)$/)?.[1];
  const idLead = atual.match(/^\/painel\/leads\/([^/]+)$/)?.[1];
  const idContrato = atual.match(/^\/painel\/contratos\/([^/]+)$/)?.[1];
  const catPortal = atual.match(/^\/painel\/portal(?:\/([a-z_]+))?$/);
  if (atual === '/painel/manual') pagina = <Manual papel={perfil.papel as PapelManual} modulosDe={modulosDe} />;
  else if (recepcao) pagina = meetingAtivo ? <MeetingPainel perfil={perfil} /> : <Aviso texto="O Meeting não está liberado no momento. Fale com a equipe de vendas." />;
  else if (idLead && (leadsLigados || (admin && leadsVisiveis))) pagina = <DetalheLead key={idLead} id={idLead} perfil={perfil} />;
  else if (atual === '/painel/leads' && leadsVisiveis) pagina = <Leads perfil={perfil} />;
  else if (atual === '/painel/escolha') pagina = <EscolhaUnidades perfil={perfil} />;
  else if (atual === '/painel/tabela') pagina = <TabelaVendas perfil={perfil} />;
  else if (idProposta && propostasVisiveis) pagina = <PaginaProposta key={idProposta} id={idProposta} perfil={perfil} />;
  else if (atual === '/painel/propostas' && propostasVisiveis) pagina = <ListaPropostas perfil={perfil} />;
  else if (idContrato && equipe && propostasVisiveis) pagina = <PaginaContrato key={idContrato} id={idContrato} perfil={perfil} />;
  else if (atual === '/painel/contratos' && equipe && propostasVisiveis) pagina = <ListaContratos />;
  else if (catPortal && portalAtivo) pagina = <Portal key={catPortal[1] ?? 'inicio'} perfil={perfil} categoria={catPortal[1]} />;
  else if ((atual === '/painel/meeting' || atual === '/painel/recepcao') && equipe && meetingAtivo) pagina = <MeetingPainel perfil={perfil} />;
  else if (atual === '/painel/meeting' && meetingAtivo) pagina = <MeetingCorretor perfil={perfil} />;
  else if (idRodada && rodadasAtivas) pagina = <DetalheRodada key={idRodada} id={idRodada} perfil={perfil} />;
  else if (atual === '/painel/treinamentos' && treinosAtivos) pagina = <Treinamentos perfil={perfil} />;
  else if (atual === '/painel/rodadas' && rodadasAtivas) pagina = <Rodadas perfil={perfil} />;
  else if (idPasta && pastasAtivas) pagina = <DetalhePasta key={idPasta} id={idPasta} perfil={perfil} />;
  else if (atual === '/painel/pastas' && pastasAtivas) pagina = <ListaPastas perfil={perfil} />;
  else if (atual === '/painel/funil' && !equipe && funilAtivo) pagina = <Funil somenteLeitura />;
  else if (atual === '/painel/funil' && equipe && funilAtivo) pagina = <Funil />;
  else if (atual === '/painel/imobiliarias' && admin) pagina = <Imobiliarias perfil={perfil} />;
  else if (atual === '/painel/empreendimento' && admin) pagina = <Empreendimento />;
  else if (atual === '/painel/corretores' && gestor) pagina = <Corretores perfil={perfil} />;
  else if (atual === '/painel/espelho' && (equipe || espelhoParceiros)) pagina = equipe ? <EspelhoEquipe perfil={perfil} /> : <EspelhoSomenteLeitura />;
  else if (atual === '/painel' && equipe) pagina = <Paineis perfil={perfil} />;
  else if (equipe) pagina = <Paineis perfil={perfil} />;
  else if (pastasAtivas) pagina = <ListaPastas perfil={perfil} />;
  else if (portalAtivo) pagina = <Portal key="inicio" perfil={perfil} />;
  else if (rodadasAtivas) pagina = <Rodadas perfil={perfil} />;
  else if (espelhoParceiros) pagina = <EspelhoSomenteLeitura />;
  else pagina = <Aviso texto="Nenhum módulo liberado no momento. Fale com a equipe de vendas." />;

  const nomeUsuario = equipe || recepcao ? perfil.nome || perfil.email : gestor ? imob : perfil.nome || perfil.email;
  const subtitulo = equipe || recepcao ? PAPEL[perfil.papel] : gestor ? 'Imobiliária' : `Corretor, ${imob}`;

  const navegar = (c: string) => (e: React.MouseEvent) => { e.preventDefault(); ir(c); };

  // sem empreendimento no endereço: vitrine (com um só empreendimento, entra direto nele)
  const empAba = slugAba ? emps.lista?.find((e) => e.slug === slugAba) ?? null : null;
  if (!slugAba && atual === inicial && rota === '/painel' && emps.lista && emps.lista.length > 0) {
    if (emps.lista.length === 1) { entrarNoEmpreendimento(emps.lista[0].slug); return null; }
    return <Vitrine perfil={perfil} />;
  }
  if (!slugAba && rota === '/painel' && !emps.lista) return <Aviso texto="Carregando…" />;
  if (slugAba && emps.lista && !empAba) { irParaVitrine(); return null; }

  return (
    <div className={`app${menuAberto ? ' menu-aberto' : ''}`}>
      <aside className="lateral" aria-label="Menu principal">
        <div className="lateral-topo">
          <a href={inicial} onClick={navegar(inicial)} className="lateral-logo"><Logo escuro /></a>
          <button className="so-celular icone-botao" onClick={() => setMenuAberto(false)} aria-label="Fechar menu"><X size={20} /></button>
        </div>
        {empAba && emps.lista && emps.lista.length > 1 && (
          <div className="emp-atual">
            <a href="/painel" onClick={(e) => { e.preventDefault(); irParaVitrine(); }}><ArrowLeft size={14} /> Todos os empreendimentos</a>
            <strong>{empAba.nome}</strong>
          </div>
        )}
        <nav className="lateral-menu">
          {menu.map((m) => (
            <a key={m.c} href={m.c} className={ativo(m.c) ? 'ativo' : ''} aria-current={ativo(m.c) ? 'page' : undefined} onClick={navegar(m.c)}>
              {m.i}<span>{m.r}</span>
            </a>
          ))}
        </nav>
        {equipe && (
          <div className="lateral-links">
            {tvAtiva && <a href="/tv" target="_blank" rel="noreferrer"><Tv size={16} /><span>Modo TV</span></a>}
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

/** Imobiliária e corretor veem só disponível ou vendida, como na TV. O andamento fica no funil. */
const paraParceiro = (u: Unidade): Unidade => (u.status === 'disponivel' ? u : { ...u, status: 'vendida' });

function EspelhoSomenteLeitura() {
  const real = useEspelho();
  const unidades = useMemo(() => real.unidades.map(paraParceiro), [real.unidades]);
  // só destaca o que mudou entre disponível e vendida (reservada -> proposta não aparece)
  const visto = useRef<Map<string, string>>(new Map());
  const [recentes, setRecentes] = useState<Record<string, number>>({});
  useEffect(() => {
    const novos: Record<string, number> = {};
    unidades.forEach((u) => {
      const antes = visto.current.get(u.id);
      if (antes !== undefined && antes !== u.status && real.recentes[u.id]) novos[u.id] = real.recentes[u.id];
      visto.current.set(u.id, u.status);
    });
    if (Object.keys(novos).length) setRecentes((r) => ({ ...r, ...novos }));
  }, [unidades, real.recentes]);
  const esp = { ...real, unidades, recentes };
  return (
    <section className="secao larga">
      <div className="secao-topo">
        <div><h2>Espelho de unidades</h2><p className="sub">Disponibilidade atualizada em tempo real.</p></div>
        <StatusConexao conectado={esp.conectado} />
      </div>
      <div className="cartao espelho-cartao">
        <Resumo unidades={esp.unidades} apenas={['disponivel', 'vendida']} />
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
