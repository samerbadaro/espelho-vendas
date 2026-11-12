import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { supabase } from './dados';
import { chamarApi, gerarSenha, type Perfil } from './util';

interface Imob { id: string; nome: string; ativa: boolean }

const PAPEL: Record<Perfil['papel'], string> = { admin: 'Administrador', vendas: 'Sec. Vendas', imobiliaria: 'Imobiliária', corretor: 'Corretor' };

/** Cadastro de imobiliárias e logins (somente administrador). */
export function Imobiliarias({ perfil }: { perfil: Perfil }) {
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
    if (i.ativa && !confirm(`Desativar ${i.nome}? O login dela deixa de acessar o sistema (as pastas continuam guardadas).`)) return;
    await supabase.from('imobiliarias').update({ ativa: !i.ativa }).eq('id', i.id);
    carregar();
  };

  const novaSenha = async (u: Perfil) => {
    if (!confirm(`Gerar uma nova senha provisória para ${u.email}?`)) return;
    const senha = gerarSenha();
    const r = await chamarApi('/api/usuarios/senha', { user_id: u.user_id, senha });
    if (r.erro) { alert(r.erro); return; }
    setSenhaMostrada({ email: u.email, senha }); carregar();
  };

  const remover = async (u: Perfil) => {
    if (!confirm(`Remover o login ${u.email}? A pessoa perde o acesso imediatamente. As pastas e o histórico continuam guardados.`)) return;
    const r = await chamarApi('/api/usuarios/remover', { user_id: u.user_id });
    if (r.erro) { alert(r.erro); return; }
    carregar();
  };

  const nomeImob = (id: string | null) => imobs.find((i) => i.id === id)?.nome ?? '—';

  return (
    <section className="secao">
      <div className="secao-topo"><h2>Imobiliárias e logins</h2></div>

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
    if (!confirm(`Gerar uma nova senha provisória para ${u.nome || u.email}?`)) return;
    const senha = gerarSenha();
    const r = await chamarApi('/api/usuarios/senha', { user_id: u.user_id, senha });
    if (r.erro) { alert(r.erro); return; }
    setSenhaMostrada({ email: u.email, senha }); carregar();
  };
  const remover = async (u: Perfil) => {
    if (!confirm(`Remover o acesso de ${u.nome || u.email}? As pastas que ele criou continuam com a imobiliária.`)) return;
    const r = await chamarApi('/api/usuarios/remover', { user_id: u.user_id });
    if (r.erro) { alert(r.erro); return; }
    carregar();
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
