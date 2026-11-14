import { useState, type FormEvent } from 'react';
import { CheckCircle2 } from 'lucide-react';
import { TelaAcesso } from './Painel';
import { chamarApi, formatarTelefone, formatarCPF, formatarCNPJ, cpfValido, cnpjValido, nomeCompleto, soDigitos } from './util';


/** Página pública: o dono da imobiliária pede o acesso e cria a própria senha. */
export function CadastroImobiliaria() {
  const [f, setF] = useState({ imobiliaria: '', cnpj: '', creci: '', cidade: '', responsavel: '', cpf: '', creci_pf: '', email: '', telefone: '', senha: '', confirma: '', site: '' });
  const [erro, setErro] = useState('');
  const [enviando, setEnviando] = useState(false);
  const [enviado, setEnviado] = useState(false);
  const campo = (k: keyof typeof f) => ({ value: f[k], onChange: (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value })) });

  const enviar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (!cnpjValido(f.cnpj)) { setErro('O CNPJ não é válido. Confira os números.'); return; }
    if (!f.creci.trim()) { setErro('Informe o CRECI PJ da imobiliária.'); return; }
    if (!nomeCompleto(f.responsavel)) { setErro('Informe o nome completo do responsável.'); return; }
    if (!cpfValido(f.cpf)) { setErro('O CPF do responsável não é válido. Confira os números.'); return; }
    if (!f.creci_pf.trim()) { setErro('Informe o CRECI PF do responsável.'); return; }
    if (f.senha.length < 8) { setErro('A senha precisa ter pelo menos 8 caracteres.'); return; }
    if (f.senha !== f.confirma) { setErro('As duas senhas não são iguais.'); return; }
    setEnviando(true);
    const r = await chamarApi('/api/cadastro-imobiliaria', { ...f, confirma: undefined });
    setEnviando(false);
    if (!r.ok) { setErro(r.erro ?? 'Não foi possível enviar o cadastro. Tente novamente.'); return; }
    setEnviado(true);
  };

  if (enviado) {
    return (
      <TelaAcesso>
        <div className="login cadastro-ok">
          <CheckCircle2 size={44} aria-hidden="true" />
          <h1>Cadastro enviado</h1>
          <p className="dica">Recebemos o cadastro da <b>{f.imobiliaria.trim()}</b>. A administração vai conferir os dados e liberar o acesso.</p>
          <p className="dica">Depois da aprovação, entre com o e-mail <b>{f.email.trim().toLowerCase()}</b> e a senha que você acabou de criar. Já com o acesso, você mesmo cadastra os seus corretores.</p>
          <a className="botao principal largo" href="/painel">Ir para o login</a>
        </div>
      </TelaAcesso>
    );
  }

  return (
    <TelaAcesso>
      <form className="login cadastro" onSubmit={enviar}>
        <h1>Cadastro de imobiliária</h1>
        <p className="dica">Preencha os dados da imobiliária e do responsável. O acesso é liberado depois da aprovação da administração.</p>

        <label>Nome da imobiliária<input {...campo('imobiliaria')} required maxLength={120} autoComplete="organization" /></label>
        <div className="duas-colunas">
          <label>CNPJ<input value={formatarCNPJ(f.cnpj)} onChange={(e) => setF((x) => ({ ...x, cnpj: soDigitos(e.target.value).slice(0, 14) }))} inputMode="numeric" required /></label>
          <label>CRECI PJ<input {...campo('creci')} maxLength={30} required /></label>
        </div>
        <label>Cidade<input {...campo('cidade')} maxLength={80} autoComplete="address-level2" /></label>
        <label>Nome completo do responsável<input {...campo('responsavel')} required maxLength={120} autoComplete="name" /></label>
        <div className="duas-colunas">
          <label>CPF do responsável<input value={formatarCPF(f.cpf)} onChange={(e) => setF((x) => ({ ...x, cpf: soDigitos(e.target.value).slice(0, 11) }))} inputMode="numeric" required /></label>
          <label>CRECI PF do responsável<input {...campo('creci_pf')} maxLength={30} required /></label>
        </div>
        <div className="duas-colunas">
          <label>E-mail (será o seu login)<input type="email" {...campo('email')} required autoComplete="email" /></label>
          <label>WhatsApp<input value={formatarTelefone(f.telefone)} onChange={(e) => setF((x) => ({ ...x, telefone: e.target.value.replace(/\D/g, '').slice(0, 11) }))} inputMode="tel" required placeholder="(64) 99999-9999" /></label>
        </div>
        <div className="duas-colunas">
          <label>Crie uma senha<input type="password" {...campo('senha')} required autoComplete="new-password" /></label>
          <label>Repita a senha<input type="password" {...campo('confirma')} required autoComplete="new-password" /></label>
        </div>
        <p className="dica">Pelo menos 8 caracteres. Esta será a senha do login master da imobiliária.</p>
        {/* campo invisível contra robôs */}
        <input className="campo-oculto" tabIndex={-1} autoComplete="off" aria-hidden="true" {...campo('site')} />

        {erro && <p className="erro" role="alert">{erro}</p>}
        <button className="botao principal largo" disabled={enviando}>{enviando ? 'Enviando…' : 'Enviar cadastro'}</button>
        <p className="dica">Já tem acesso? <a href="/painel">Entrar no painel</a></p>
      </form>
    </TelaAcesso>
  );
}
