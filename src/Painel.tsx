import { useCallback, useEffect, useState, type FormEvent } from 'react';
import type { Session } from '@supabase/supabase-js';
import {
  supabase, configurado, useEspelho, STATUS, rotuloStatus, formatarArea, formatarDataHora,
  type Unidade, type Status,
} from './dados';
import { Predio, Resumo } from './Predio';
import { Aviso, StatusConexao, useTitulo } from './Publico';

interface Perfil { email: string; nome: string | null; papel: 'admin' | 'vendas' }
interface Registro {
  id: number; numero: string; status_anterior: Status | null; status_novo: Status;
  motivo: string | null; usuario_email: string | null; criado_em: string;
}

/** Painel da Sec. Vendas: exige login e perfil cadastrado. */
export function Painel() {
  const [sessao, setSessao] = useState<Session | null | undefined>(undefined);
  const [perfil, setPerfil] = useState<Perfil | null | undefined>(undefined);

  useEffect(() => {
    if (!configurado) { setSessao(null); return; }
    supabase.auth.getSession().then(({ data }) => setSessao(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSessao(s));
    return () => data.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!sessao) { setPerfil(sessao === null ? null : undefined); return; }
    supabase.from('perfis').select('email, nome, papel').eq('user_id', sessao.user.id).maybeSingle()
      .then(({ data }) => setPerfil((data as Perfil) ?? null));
  }, [sessao]);

  if (!configurado) return <Aviso texto="O sistema ainda não foi conectado ao banco de dados." />;
  if (sessao === undefined) return <Aviso texto="Carregando…" />;
  if (!sessao) return <Login />;
  if (perfil === undefined) return <Aviso texto="Carregando…" />;
  if (!perfil) {
    return (
      <div className="aviso">
        <p>O usuário {sessao.user.email} não tem acesso ao painel. Peça a liberação ao administrador.</p>
        <button className="botao" onClick={() => supabase.auth.signOut()}>Sair</button>
      </div>
    );
  }
  return <AreaEquipe perfil={perfil} />;
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
    <form className="login" onSubmit={entrar}>
      <h1>Painel de vendas</h1>
      <label>E-mail<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
      <label>Senha<input type="password" autoComplete="current-password" value={senha} onChange={(e) => setSenha(e.target.value)} required /></label>
      {erro && <p className="erro" role="alert">{erro}</p>}
      <button className="botao principal" disabled={enviando}>{enviando ? 'Entrando…' : 'Entrar'}</button>
    </form>
  );
}

function AreaEquipe({ perfil }: { perfil: Perfil }) {
  const esp = useEspelho();
  const [selecionada, setSelecionada] = useState<Unidade | null>(null);
  const [historico, setHistorico] = useState<Registro[]>([]);
  useTitulo(esp.config ? `Painel, ${esp.config.nome_empreendimento}` : undefined);

  const carregarHistorico = useCallback(async () => {
    const { data } = await supabase.from('historico')
      .select('id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em')
      .order('criado_em', { ascending: false }).limit(20);
    setHistorico((data as Registro[]) ?? []);
  }, []);
  // recarrega o histórico sempre que algo muda no espelho
  const ultimaMudanca = Math.max(0, ...Object.values(esp.recentes));
  useEffect(() => { carregarHistorico(); }, [carregarHistorico, ultimaMudanca]);

  // mantém a unidade aberta no diálogo sincronizada com o tempo real
  const atual = selecionada ? esp.unidades.find((u) => u.id === selecionada.id) ?? selecionada : null;

  const alternarPublico = async () => {
    if (!esp.config) return;
    const ativar = !esp.config.publico_ativo;
    if (!ativar && !confirm('Tirar o link público do ar? Quem estiver com o link aberto deixa de ver o espelho.')) return;
    const { error } = await supabase.rpc('definir_publico', { p_ativo: ativar });
    if (error) alert('Não foi possível alterar o link público. Tente novamente.');
    esp.recarregar();
  };

  return (
    <div className="painel">
      <header className="topo">
        <h1 className="nome">{esp.config?.nome_empreendimento}</h1>
        <StatusConexao conectado={esp.conectado} />
        <div className="topo-acoes">
          <span className="usuario">{perfil.nome || perfil.email}</span>
          <button className="botao" onClick={() => supabase.auth.signOut()}>Sair</button>
        </div>
      </header>

      <div className="painel-corpo">
        <section className="painel-espelho" aria-label="Espelho">
          <Resumo unidades={esp.unidades} />
          <p className="dica">Toque em uma unidade para alterar o status.</p>
          <Predio unidades={esp.unidades} recentes={esp.recentes} aoSelecionar={setSelecionada} />
        </section>

        <aside className="painel-lateral">
          {perfil.papel === 'admin' && esp.config && (
            <div className="caixa">
              <h2>Link público</h2>
              <p>{esp.config.publico_ativo ? 'No ar. Qualquer pessoa com o link vê o espelho.' : 'Fora do ar. Só a equipe vê o espelho.'}</p>
              <div className="links">
                <a href="/" target="_blank" rel="noreferrer">Abrir link público</a>
                <a href="/tv" target="_blank" rel="noreferrer">Abrir modo TV</a>
              </div>
              <button className="botao" onClick={alternarPublico}>
                {esp.config.publico_ativo ? 'Tirar do ar' : 'Colocar no ar'}
              </button>
            </div>
          )}
          <div className="caixa">
            <h2>Últimas alterações</h2>
            {historico.length === 0 ? <p className="vazio">Nenhuma alteração ainda.</p> : (
              <ol className="historico">
                {historico.map((h) => (
                  <li key={h.id}>
                    <strong>{h.numero}</strong> {h.status_anterior ? rotuloStatus(h.status_anterior).toLowerCase() : ''} para{' '}
                    <span className={`etiqueta s-${h.status_novo}`}>{rotuloStatus(h.status_novo).toLowerCase()}</span>
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
          aoSalvar={(u) => { esp.atualizarLocal(u); setSelecionada(null); carregarHistorico(); }}
          aoConflito={() => esp.recarregar()}
        />
      )}
    </div>
  );
}

const EXIGE_MOTIVO = (de: Status, para: Status) =>
  (de === 'reservada' || de === 'vendida') && (para === 'disponivel' || para === 'bloqueada');

function DialogoUnidade({ unidade, aoFechar, aoSalvar, aoConflito }: {
  unidade: Unidade; aoFechar: () => void; aoSalvar: (u: Unidade) => void; aoConflito: () => void;
}) {
  const [novo, setNovo] = useState<Status | null>(null);
  const [motivo, setMotivo] = useState('');
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);
  const [registros, setRegistros] = useState<Registro[]>([]);
  const [versaoAberta] = useState(unidade.versao);

  useEffect(() => {
    supabase.from('historico')
      .select('id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em')
      .eq('unidade_id', unidade.id).order('criado_em', { ascending: false }).limit(10)
      .then(({ data }) => setRegistros((data as Registro[]) ?? []));
  }, [unidade.id, unidade.versao]);

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && aoFechar();
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [aoFechar]);

  const mudouPorOutro = unidade.versao !== versaoAberta;
  const precisaMotivo = novo ? EXIGE_MOTIVO(unidade.status, novo) : false;

  const salvar = async () => {
    if (!novo) return;
    if (precisaMotivo && !motivo.trim()) { setErro('Informe o motivo para desfazer a reserva ou a venda.'); return; }
    setSalvando(true); setErro('');
    const { data, error } = await supabase.rpc('alterar_status', {
      p_unidade_id: unidade.id, p_status: novo, p_versao: versaoAberta, p_motivo: motivo.trim() || null,
    });
    setSalvando(false);
    if (error) {
      if (error.message.includes('CONFLITO')) {
        setErro('Outra pessoa alterou esta unidade agora há pouco. Feche, confira o status atual e tente de novo.');
        aoConflito();
      } else if (error.message.includes('MOTIVO_OBRIGATORIO')) {
        setErro('Informe o motivo para desfazer a reserva ou a venda.');
      } else if (error.message.includes('SEM_PERMISSAO')) {
        setErro('Seu usuário não tem permissão para alterar unidades.');
      } else {
        setErro('Não foi possível salvar. Verifique a internet e tente novamente.');
      }
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

        {novo && (
          <label className="campo-motivo">
            {precisaMotivo ? 'Motivo (obrigatório)' : 'Observação (opcional)'}
            <textarea rows={2} value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={300}
              placeholder={precisaMotivo ? 'Ex.: cliente desistiu da compra' : 'Ex.: corretor responsável'} />
            <small>Não registre CPF nem dados pessoais do comprador aqui.</small>
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
