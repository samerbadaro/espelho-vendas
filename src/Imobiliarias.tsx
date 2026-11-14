import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { supabase } from './dados';
import { chamarApi, gerarSenha, type Perfil } from './util';
import { useDialogos } from './ui';

interface Imob { id: string; nome: string; ativa: boolean }

const PAPEL: Record<Perfil['papel'], string> = { admin: 'Administrador', vendas: 'Sec. Vendas', imobiliaria: 'Imobiliária', corretor: 'Corretor' };

/** Cadastro de imobiliárias e logins (somente administrador). */
export function Imobiliarias({ perfil }: { perfil: Perfil }) {
  const { confirmar, avisar } = useDialogos();
  const [imobs, setImobs] = useState<Imob[]>([]);
  const [usuarios, setUsuarios] = useState<Perfil[]>([]);
  const [novaImob, setNovaImob] = useState('');
  const [erroImob, setErroImob] = useState('');
  const [senhaMostrada, setSenhaMostrada] = useState<{ email: string; senha: string } | null>(null);

  const carregar = useCallback(async () => {
    const [i, u] = await Promise.all([
      supabase.from('imobiliarias').select('id, nome, ativa').order('nome'),
      supabase.from('perfis').select('user_id, email, nome, papel, imobiliaria_id, trocar_senha').order('email'),
    ]);
    setImobs((i.data as Imob[]) ?? []);
    setUsuarios((u.data as Perfil[]) ?? []);
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const criarImob = async (e: FormEvent) => {
    e.preventDefault(); setErroImob('');
    const nome = novaImob.trim();
    if (nome.length < 2) { setErroImob('Informe o nome da imobiliária.'); return; }
    const { error } = await supabase.from('imobiliarias').insert({ nome });
    if (error) { setErroImob(error.code === '23505' ? 'Já existe uma imobiliária com esse nome.' : 'Não foi possível cadastrar.'); return; }
    setNovaImob(''); carregar();
  };

  const alternarAtiva = async (i: Imob) => {
    if (i.ativa && !(await confirmar({ titulo: `Desativar ${i.nome}?`, texto: 'Os logins da imobiliária e dos corretores dela deixam de acessar o sistema. As pastas continuam guardadas.', confirmar: 'Desativar', perigo: true }))) return;
    await supabase.from('imobiliarias').update({ ativa: !i.ativa }).eq('id', i.id);
    carregar();
  };

  const novaSenha = async (u: Perfil) => {
    if (!(await confirmar({ titulo: 'Gerar nova senha provisória?', texto: `A senha atual de ${u.email} deixa de funcionar.`, confirmar: 'Gerar senha' }))) return;
    const senha = gerarSenha();
    const r = await chamarApi('/api/usuarios/senha', { user_id: u.user_id, senha });
    if (r.erro) { avisar(r.erro, 'erro'); return; }
    setSenhaMostrada({ email: u.email, senha }); carregar();
  };

  const remover = async (u: Perfil) => {
    if (!(await confirmar({ titulo: `Remover o login ${u.email}?`, texto: 'A pessoa perde o acesso imediatamente. As pastas e o histórico continuam guardados.', confirmar: 'Remover', perigo: true }))) return;
    const r = await chamarApi('/api/usuarios/remover', { user_id: u.user_id });
    if (r.erro) { avisar(r.erro, 'erro'); return; }
    avisar('Login removido.'); carregar();
  };

  const nomeImob = (id: string | null) => imobs.find((i) => i.id === id)?.nome ?? '—';

  return (
    <section className="secao">
      <div className="secao-topo">
        <div>
          <h2>Imobiliárias e logins</h2>
          <p className="sub">Link de cadastro para os donos de imobiliária: <strong className="mono">{`${location.host}/cadastro`}</strong>{' '}
            <button className="botao pequeno" onClick={() => { navigator.clipboard?.writeText(`${location.origin}/cadastro`); avisar('Link copiado.'); }}>Copiar link</button>
          </p>
        </div>
      </div>

      <Solicitacoes imobs={imobs} aoMudar={carregar} />

      {senhaMostrada && (
        <div className="senha-gerada" role="status">
          <p>Login <strong>{senhaMostrada.email}</strong>, senha provisória <strong className="mono">{senhaMostrada.senha}</strong></p>
          <p className="dica">Envie esses dados para a pessoa por um canal seguro. No primeiro acesso o sistema pede para ela criar uma senha própria. Esta senha não será mostrada de novo.</p>
          <button className="botao pequeno" onClick={() => setSenhaMostrada(null)}>Já anotei</button>
        </div>
      )}

      <div className="duas-colunas">
        <div className="cartao">
          <h3>Imobiliárias</h3>
          <form className="linha-form" onSubmit={criarImob}>
            <input placeholder="Nome da imobiliária" value={novaImob} onChange={(e) => setNovaImob(e.target.value)} maxLength={120} />
            <button className="botao principal">Cadastrar</button>
          </form>
          {erroImob && <p className="erro">{erroImob}</p>}
          {imobs.length === 0 ? <p className="vazio">Nenhuma imobiliária cadastrada.</p> : (
            <ul className="lista-simples">
              {imobs.map((i) => (
                <li key={i.id}>
                  <span className={i.ativa ? '' : 'inativa'}>{i.nome}{!i.ativa && ' (desativada)'}</span>
                  <button className="botao pequeno" onClick={() => alternarAtiva(i)}>{i.ativa ? 'Desativar' : 'Reativar'}</button>
                </li>
              ))}
            </ul>
          )}
        </div>

        <NovoLogin imobs={imobs.filter((i) => i.ativa)} aoCriar={(email, senha) => { setSenhaMostrada({ email, senha }); carregar(); }} />
      </div>

      <div className="cartao">
        <h3>Logins</h3>
        <table className="tabela compacta">
          <thead><tr><th>E-mail</th><th>Perfil</th><th>Imobiliária</th><th>Situação</th><th></th></tr></thead>
          <tbody>
            {usuarios.map((u) => (
              <tr key={u.user_id}>
                <td>{u.email}{u.nome ? ` (${u.nome})` : ''}</td>
                <td>{PAPEL[u.papel]}</td>
                <td>{u.imobiliaria_id ? nomeImob(u.imobiliaria_id) : '—'}</td>
                <td>{u.trocar_senha ? 'Aguardando primeiro acesso' : 'Ativo'}</td>
                <td className="acoes-linha">
                  {u.user_id !== perfil.user_id && (
                    <>
                      <button className="botao pequeno" onClick={() => novaSenha(u)}>Nova senha</button>
                      <button className="botao pequeno recusar" onClick={() => remover(u)}>Remover</button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function NovoLogin({ imobs, aoCriar }: { imobs: Imob[]; aoCriar: (email: string, senha: string) => void }) {
  const [email, setEmail] = useState('');
  const [nome, setNome] = useState('');
  const [papel, setPapel] = useState<Perfil['papel']>('imobiliaria');
  const [imob, setImob] = useState('');
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);

  const criar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    const comImob = papel === 'imobiliaria' || papel === 'corretor';
    if (comImob && !imob) { setErro('Escolha a imobiliária.'); return; }
    if (papel === 'corretor' && !nome.trim()) { setErro('Informe o nome do corretor.'); return; }
    const senha = gerarSenha();
    setSalvando(true);
    const r = await chamarApi('/api/usuarios', { email, nome, papel, imobiliaria_id: comImob ? imob : null, senha });
    setSalvando(false);
    if (r.erro) { setErro(r.erro); return; }
    aoCriar(email.trim().toLowerCase(), senha);
    setEmail(''); setNome(''); setImob('');
  };

  return (
    <form className="cartao" onSubmit={criar}>
      <h3>Novo login</h3>
      <div className="grade-campos">
        <label className="largo">E-mail<input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></label>
        <label className="largo">{papel === 'corretor' ? 'Nome do corretor' : 'Nome de quem vai usar (opcional)'}<input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={120} /></label>
        <label>Perfil
          <select value={papel} onChange={(e) => setPapel(e.target.value as Perfil['papel'])}>
            <option value="imobiliaria">Imobiliária (vê todas as pastas dela)</option>
            <option value="corretor">Corretor (vê só as pastas que criar)</option>
            <option value="vendas">Sec. Vendas</option>
            <option value="admin">Administrador</option>
          </select>
        </label>
        {(papel === 'imobiliaria' || papel === 'corretor') && (
          <label>Imobiliária
            <select value={imob} onChange={(e) => setImob(e.target.value)} required>
              <option value="">Escolha…</option>
              {imobs.map((i) => <option key={i.id} value={i.id}>{i.nome}</option>)}
            </select>
          </label>
        )}
      </div>
      {erro && <p className="erro">{erro}</p>}
      <p className="dica">O sistema gera uma senha provisória, mostrada uma única vez.</p>
      <button className="botao principal" disabled={salvando}>{salvando ? 'Criando…' : 'Criar login'}</button>
    </form>
  );
}

/** Imobiliária gerencia os logins dos seus corretores. */
export function Corretores({ perfil }: { perfil: Perfil }) {
  const { confirmar, avisar } = useDialogos();
  const [lista, setLista] = useState<Perfil[]>([]);
  const [email, setEmail] = useState('');
  const [nome, setNome] = useState('');
  const [erro, setErro] = useState('');
  const [salvando, setSalvando] = useState(false);
  const [senhaMostrada, setSenhaMostrada] = useState<{ email: string; senha: string } | null>(null);

  const carregar = useCallback(async () => {
    const { data } = await supabase.from('perfis').select('user_id, email, nome, papel, imobiliaria_id, trocar_senha')
      .eq('papel', 'corretor').order('nome');
    setLista((data as Perfil[]) ?? []);
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const criar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (!nome.trim()) { setErro('Informe o nome do corretor.'); return; }
    const senha = gerarSenha();
    setSalvando(true);
    const r = await chamarApi('/api/usuarios', { email, nome, papel: 'corretor', imobiliaria_id: perfil.imobiliaria_id, senha });
    setSalvando(false);
    if (r.erro) { setErro(r.erro); return; }
    setSenhaMostrada({ email: email.trim().toLowerCase(), senha }); setEmail(''); setNome(''); carregar();
  };
  const novaSenha = async (u: Perfil) => {
    if (!(await confirmar({ titulo: 'Gerar nova senha provisória?', texto: `A senha atual de ${u.nome || u.email} deixa de funcionar.`, confirmar: 'Gerar senha' }))) return;
    const senha = gerarSenha();
    const r = await chamarApi('/api/usuarios/senha', { user_id: u.user_id, senha });
    if (r.erro) { avisar(r.erro, 'erro'); return; }
    setSenhaMostrada({ email: u.email, senha }); carregar();
  };
  const remover = async (u: Perfil) => {
    if (!(await confirmar({ titulo: `Remover o acesso de ${u.nome || u.email}?`, texto: 'As pastas que ele criou continuam com a imobiliária.', confirmar: 'Remover', perigo: true }))) return;
    const r = await chamarApi('/api/usuarios/remover', { user_id: u.user_id });
    if (r.erro) { avisar(r.erro, 'erro'); return; }
    avisar('Acesso removido.'); carregar();
  };

  return (
    <section className="secao">
      <div className="secao-topo"><h2>Corretores</h2></div>
      <p className="sub" style={{ marginTop: -8, marginBottom: 16 }}>Cada corretor vê somente as pastas que ele mesmo criar. Você vê as pastas de todos.</p>
      {senhaMostrada && (
        <div className="senha-gerada" role="status">
          <p>Login <strong>{senhaMostrada.email}</strong>, senha provisória <strong className="mono">{senhaMostrada.senha}</strong></p>
          <p className="dica">Envie esses dados ao corretor. No primeiro acesso ele cria uma senha própria. Esta senha não será mostrada de novo.</p>
          <button className="botao pequeno" onClick={() => setSenhaMostrada(null)}>Já anotei</button>
        </div>
      )}
      <form className="cartao" onSubmit={criar}>
        <h3>Novo corretor</h3>
        <div className="grade-campos">
          <label>Nome do corretor<input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={120} required /></label>
          <label>E-mail<input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        </div>
        {erro && <p className="erro">{erro}</p>}
        <div className="acoes"><button className="botao principal" disabled={salvando}>{salvando ? 'Criando…' : 'Criar acesso'}</button></div>
      </form>
      <div className="cartao">
        <h3>Corretores com acesso</h3>
        {lista.length === 0 ? <p className="vazio">Nenhum corretor cadastrado ainda.</p> : (
          <table className="tabela compacta">
            <thead><tr><th>Nome</th><th>E-mail</th><th>Situação</th><th></th></tr></thead>
            <tbody>
              {lista.map((u) => (
                <tr key={u.user_id}>
                  <td>{u.nome}</td><td>{u.email}</td>
                  <td>{u.trocar_senha ? 'Aguardando primeiro acesso' : 'Ativo'}</td>
                  <td className="acoes-linha">
                    <button className="botao pequeno" onClick={() => novaSenha(u)}>Nova senha</button>
                    <button className="botao pequeno recusar" onClick={() => remover(u)}>Remover</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

// =====================================================================
// Solicitações de cadastro vindas do link público
// =====================================================================
interface Solicitacao {
  id: string; imobiliaria_nome: string; cnpj: string | null; creci: string | null; cidade: string | null;
  responsavel: string; email: string; telefone: string; status: 'pendente' | 'aprovada' | 'recusada';
  motivo: string | null; criada_em: string; analisada_em: string | null;
}

const ERROS_SOL: Record<string, string> = {
  NOME_EM_USO: 'Já existe uma imobiliária com esse nome. Mude o nome ou vincule à imobiliária existente.',
  SOLICITACAO_JA_ANALISADA: 'Esta solicitação já foi analisada.',
  JA_TEM_ACESSO: 'Este login já tem acesso.',
  MOTIVO_OBRIGATORIO: 'Informe o motivo da recusa.',
};
const cnpjFmt = (d: string | null) => (d && d.length === 14 ? d.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5') : d ?? '');
const telFmt = (d: string) => (d.length === 11 ? d.replace(/^(\d{2})(\d{5})(\d{4})$/, '($1) $2-$3') : d.replace(/^(\d{2})(\d{4})(\d{4})$/, '($1) $2-$3'));

function Solicitacoes({ imobs, aoMudar }: { imobs: Imob[]; aoMudar: () => void }) {
  const { avisar } = useDialogos();
  const [lista, setLista] = useState<Solicitacao[]>([]);
  const [verTodas, setVerTodas] = useState(false);
  const [aprovando, setAprovando] = useState<Solicitacao | null>(null);
  const [recusando, setRecusando] = useState<Solicitacao | null>(null);

  const carregar = useCallback(async () => {
    const { data } = await supabase.from('solicitacoes_imobiliaria').select('*').order('criada_em', { ascending: false });
    setLista((data as Solicitacao[]) ?? []);
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const pendentes = lista.filter((s) => s.status === 'pendente');
  const mostradas = verTodas ? lista : pendentes;
  if (!lista.length) return null;

  return (
    <div className="cartao solicitacoes">
      <div className="cartao-topo">
        <h3>Solicitações de cadastro {pendentes.length > 0 && <span className="selo sr-encerrada">{pendentes.length} aguardando</span>}</h3>
        <button className="botao pequeno" onClick={() => setVerTodas((v) => !v)}>{verTodas ? 'Só as pendentes' : 'Ver histórico'}</button>
      </div>
      {mostradas.length === 0 ? <p className="vazio">Nenhuma solicitação aguardando aprovação.</p> : (
        <ul className="lista-solicitacoes">
          {mostradas.map((s) => (
            <li key={s.id}>
              <div className="sol-info">
                <strong>{s.imobiliaria_nome}</strong>
                <span>{[s.cidade, s.cnpj && `CNPJ ${cnpjFmt(s.cnpj)}`, s.creci && `CRECI ${s.creci}`].filter(Boolean).join(' · ')}</span>
                <span>{s.responsavel} · {s.email} · {telFmt(s.telefone)}</span>
                <small>Enviado em {new Date(s.criada_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}
                  {s.status !== 'pendente' && ` · ${s.status === 'aprovada' ? 'Aprovada' : `Recusada${s.motivo ? `: ${s.motivo}` : ''}`}`}</small>
              </div>
              {s.status === 'pendente' && (
                <div className="sol-acoes">
                  <button className="botao pequeno recusar" onClick={() => setRecusando(s)}>Recusar</button>
                  <button className="botao pequeno principal" onClick={() => setAprovando(s)}>Aprovar</button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {aprovando && <Aprovar sol={aprovando} imobs={imobs} aoFechar={() => setAprovando(null)}
        aoAprovar={() => { setAprovando(null); avisar('Imobiliária aprovada. O responsável já pode entrar com a senha que criou.'); carregar(); aoMudar(); }} />}
      {recusando && <Recusar sol={recusando} aoFechar={() => setRecusando(null)}
        aoRecusar={() => { setRecusando(null); avisar('Solicitação recusada.'); carregar(); }} />}
    </div>
  );
}

function Aprovar({ sol, imobs, aoFechar, aoAprovar }: { sol: Solicitacao; imobs: Imob[]; aoFechar: () => void; aoAprovar: () => void }) {
  const parecida = imobs.find((i) => i.nome.toLowerCase().trim() === sol.imobiliaria_nome.toLowerCase().trim());
  const [modo, setModo] = useState<'nova' | 'existente'>(parecida ? 'existente' : 'nova');
  const [nome, setNome] = useState(sol.imobiliaria_nome);
  const [existente, setExistente] = useState(parecida?.id ?? '');
  const [erro, setErro] = useState('');
  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (modo === 'existente' && !existente) { setErro('Escolha a imobiliária.'); return; }
    const { error } = await supabase.rpc('aprovar_solicitacao', {
      p_id: sol.id, p_nome_imobiliaria: modo === 'nova' ? nome : null, p_imobiliaria_existente: modo === 'existente' ? existente : null,
    });
    if (error) { setErro(ERROS_SOL[error.message] ?? 'Não foi possível aprovar.'); return; }
    aoAprovar();
  };
  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="apr-titulo" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="apr-titulo">Aprovar {sol.imobiliaria_nome}</h2>
        <p className="sub">{sol.responsavel} ({sol.email}) passa a ser o login master da imobiliária, com a senha que criou no cadastro.</p>
        <label className="check"><input type="radio" checked={modo === 'nova'} onChange={() => setModo('nova')} /> Cadastrar como nova imobiliária</label>
        {modo === 'nova' && <div className="campos"><label className="largo">Nome da imobiliária<input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={120} /></label></div>}
        <label className="check"><input type="radio" checked={modo === 'existente'} onChange={() => setModo('existente')} /> Vincular a uma imobiliária já cadastrada</label>
        {modo === 'existente' && (
          <div className="campos"><label className="largo">Imobiliária
            <select value={existente} onChange={(e) => setExistente(e.target.value)}>
              <option value="">Escolha</option>
              {imobs.map((i) => <option key={i.id} value={i.id}>{i.nome}{i.ativa ? '' : ' (inativa)'}</option>)}
            </select></label></div>
        )}
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal">Aprovar e liberar acesso</button>
        </div>
      </form>
    </div>
  );
}

function Recusar({ sol, aoFechar, aoRecusar }: { sol: Solicitacao; aoFechar: () => void; aoRecusar: () => void }) {
  const [motivo, setMotivo] = useState('');
  const [erro, setErro] = useState('');
  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    const { error } = await supabase.rpc('recusar_solicitacao', { p_id: sol.id, p_motivo: motivo });
    if (error) { setErro(ERROS_SOL[error.message] ?? 'Não foi possível recusar.'); return; }
    aoRecusar();
  };
  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="rec-titulo" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="rec-titulo">Recusar {sol.imobiliaria_nome}</h2>
        <p className="sub">O responsável vê o motivo ao tentar entrar e pode corrigir e enviar de novo.</p>
        <div className="campos"><label className="largo">Motivo<input value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={200} autoFocus placeholder="Ex.: imobiliária não identificada" /></label></div>
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao recusar">Recusar</button>
        </div>
      </form>
    </div>
  );
}
