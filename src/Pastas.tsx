import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { supabase, formatarDataHora } from './dados';
import {
  ir, soDigitos, formatarCPF, cpfValido, formatarTelefone, formatarData, formatarTamanho,
  ESTADOS_CIVIS, STATUS_PASTA, rotuloPasta, temConjuge, ROTULO_DOC,
  type EstadoCivil, type StatusPasta, type StatusDocumento, type Perfil,
} from './util';

interface PastaResumo {
  id: string; codigo: string; comprador_nome: string; comprador_cpf: string; status: StatusPasta;
  criada_em: string; imobiliaria_id: string; criado_por: string | null;
  imobiliarias: { nome: string } | null; unidades: { numero: string } | null;
}

const ehEquipe = (p: Perfil) => p.papel === 'admin' || p.papel === 'vendas';

// =====================================================================
// Lista de pastas
// =====================================================================
export function ListaPastas({ perfil }: { perfil: Perfil }) {
  const [pastas, setPastas] = useState<PastaResumo[] | null>(null);
  const [busca, setBusca] = useState('');
  const [status, setStatus] = useState('');
  const [imob, setImob] = useState('');
  const [erro, setErro] = useState('');
  const equipe = ehEquipe(perfil);
  const verCriador = equipe || perfil.papel === 'imobiliaria';
  const [corretores, setCorretores] = useState<Record<string, string>>({});

  useEffect(() => {
    if (verCriador) supabase.from('perfis').select('email, nome').then(({ data }) => {
      const m: Record<string, string> = {};
      ((data as { email: string; nome: string | null }[]) ?? []).forEach((x) => { m[x.email] = x.nome || x.email; });
      setCorretores(m);
    });
  }, [verCriador]);

  useEffect(() => {
    supabase.from('pastas')
      .select('id, codigo, comprador_nome, comprador_cpf, status, criada_em, imobiliaria_id, criado_por, imobiliarias(nome), unidades(numero)')
      .order('criada_em', { ascending: false })
      .then(({ data, error }) => {
        if (error) setErro('Não foi possível carregar as pastas. Recarregue a página.');
        setPastas((data as unknown as PastaResumo[]) ?? []);
      });
  }, []);

  const imobiliarias = useMemo(() => {
    const m = new Map<string, string>();
    (pastas ?? []).forEach((p) => p.imobiliarias && m.set(p.imobiliaria_id, p.imobiliarias.nome));
    return [...m.entries()].sort((a, b) => a[1].localeCompare(b[1], 'pt-BR'));
  }, [pastas]);

  const filtradas = useMemo(() => {
    const t = busca.trim().toLowerCase();
    const d = soDigitos(busca);
    return (pastas ?? []).filter((p) =>
      (!t || p.comprador_nome.toLowerCase().includes(t) || p.codigo.toLowerCase().includes(t)
        || (d.length >= 3 && p.comprador_cpf.includes(d)) || (p.unidades?.numero ?? '').includes(t))
      && (!status || p.status === status)
      && (!imob || p.imobiliaria_id === imob));
  }, [pastas, busca, status, imob, corretores]);

  return (
    <section className="secao">
      <div className="secao-topo">
        <h2>Pastas de compradores</h2>
        <button className="botao principal" onClick={() => ir('/painel/pastas/nova')}>Nova pasta</button>
      </div>
      <div className="filtros">
        <input type="search" placeholder={verCriador ? "Buscar por nome, CPF, código, unidade ou corretor" : "Buscar por nome, CPF, código ou unidade"} value={busca} onChange={(e) => setBusca(e.target.value)} />
        <select value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Filtrar por status">
          <option value="">Todos os status</option>
          {STATUS_PASTA.map((s) => <option key={s.valor} value={s.valor}>{s.rotulo}</option>)}
        </select>
        {equipe && (
          <select value={imob} onChange={(e) => setImob(e.target.value)} aria-label="Filtrar por imobiliária">
            <option value="">Todas as imobiliárias</option>
            {imobiliarias.map(([id, nome]) => <option key={id} value={id}>{nome}</option>)}
          </select>
        )}
      </div>
      {erro && <p className="erro">{erro}</p>}
      {pastas === null ? <p className="vazio">Carregando…</p> : filtradas.length === 0 ? (
        <p className="vazio">{pastas.length === 0 ? 'Nenhuma pasta cadastrada ainda. Use “Nova pasta” para começar.' : 'Nenhuma pasta encontrada com esses filtros.'}</p>
      ) : (
        <table className="tabela">
          <thead>
            <tr>
              <th>Código</th><th>Comprador</th><th>CPF</th>
              {equipe && <th>Imobiliária</th>}
              {verCriador && <th>Cadastrada por</th>}
              <th>Unidade</th><th>Status</th><th>Cadastro</th>
            </tr>
          </thead>
          <tbody>
            {filtradas.map((p) => (
              <tr key={p.id} onClick={() => ir(`/painel/pastas/${p.id}`)} tabIndex={0}
                onKeyDown={(e) => e.key === 'Enter' && ir(`/painel/pastas/${p.id}`)}>
                <td className="mono">{p.codigo}</td>
                <td><strong>{p.comprador_nome}</strong></td>
                <td>{formatarCPF(p.comprador_cpf)}</td>
                {equipe && <td>{p.imobiliarias?.nome}</td>}
                {verCriador && <td>{p.criado_por ? corretores[p.criado_por] ?? p.criado_por : '—'}</td>}
                <td>{p.unidades?.numero ?? '—'}</td>
                <td><span className={`selo sp-${p.status}`}>{rotuloPasta(p.status)}</span></td>
                <td>{formatarData(p.criada_em)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}

// =====================================================================
// Detalhe / cadastro da pasta
// =====================================================================
interface Pasta {
  id: string; codigo: string; imobiliaria_id: string; unidade_id: string | null; status: StatusPasta;
  comprador_nome: string; comprador_cpf: string; comprador_nascimento: string | null;
  comprador_telefone: string | null; comprador_email: string | null; estado_civil: EstadoCivil;
  conjuge_nome: string | null; conjuge_cpf: string | null; conjuge_nascimento: string | null;
  conjuge_telefone: string | null; conjuge_email: string | null;
  dados_bancarios: string | null; observacoes: string | null; criado_por: string | null; criada_em: string;
  imobiliarias?: { nome: string } | null; unidades?: { numero: string } | null;
}
type Form = Omit<Pasta, 'id' | 'codigo' | 'unidade_id' | 'status' | 'criado_por' | 'criada_em' | 'imobiliarias' | 'unidades'>;

const FORM_VAZIO: Form = {
  imobiliaria_id: '', comprador_nome: '', comprador_cpf: '', comprador_nascimento: null, comprador_telefone: '',
  comprador_email: '', estado_civil: 'solteiro', conjuge_nome: '', conjuge_cpf: '', conjuge_nascimento: null,
  conjuge_telefone: '', conjuge_email: '', dados_bancarios: '', observacoes: '',
};

export function DetalhePasta({ id, perfil }: { id: string; perfil: Perfil }) {
  const nova = id === 'nova';
  const equipe = ehEquipe(perfil);
  const [pasta, setPasta] = useState<Pasta | null>(null);
  const [form, setForm] = useState<Form>(FORM_VAZIO);
  const [editando, setEditando] = useState(nova);
  const [erro, setErro] = useState('');
  const [aviso, setAviso] = useState('');
  const [salvando, setSalvando] = useState(false);
  const [imobiliarias, setImobiliarias] = useState<{ id: string; nome: string }[]>([]);
  const [recarga, setRecarga] = useState(0);

  const carregar = useCallback(async () => {
    if (nova) return;
    const { data, error } = await supabase.from('pastas').select('*, imobiliarias(nome), unidades(numero)').eq('id', id).maybeSingle();
    if (error || !data) { setErro('Pasta não encontrada ou sem permissão de acesso.'); return; }
    setPasta(data as Pasta);
    const p = data as Pasta;
    setForm({
      imobiliaria_id: p.imobiliaria_id, comprador_nome: p.comprador_nome, comprador_cpf: formatarCPF(p.comprador_cpf),
      comprador_nascimento: p.comprador_nascimento, comprador_telefone: formatarTelefone(p.comprador_telefone),
      comprador_email: p.comprador_email ?? '', estado_civil: p.estado_civil, conjuge_nome: p.conjuge_nome ?? '',
      conjuge_cpf: formatarCPF(p.conjuge_cpf), conjuge_nascimento: p.conjuge_nascimento,
      conjuge_telefone: formatarTelefone(p.conjuge_telefone), conjuge_email: p.conjuge_email ?? '',
      dados_bancarios: p.dados_bancarios ?? '', observacoes: p.observacoes ?? '',
    });
  }, [id, nova]);

  useEffect(() => { carregar(); }, [carregar, recarga]);
  useEffect(() => {
    if (equipe) supabase.from('imobiliarias').select('id, nome').eq('ativa', true).order('nome')
      .then(({ data }) => setImobiliarias((data as { id: string; nome: string }[]) ?? []));
  }, [equipe]);

  const campo = (k: keyof Form) => ({
    value: (form[k] as string) ?? '',
    onChange: (e: { target: { value: string } }) => setForm((f) => ({ ...f, [k]: e.target.value })),
  });

  const salvar = async (e: FormEvent) => {
    e.preventDefault();
    setErro(''); setAviso('');
    if (form.comprador_nome.trim().length < 3) { setErro('Informe o nome completo do comprador.'); return; }
    if (!cpfValido(form.comprador_cpf)) { setErro('O CPF do comprador não é válido. Confira os números.'); return; }
    const casal = temConjuge(form.estado_civil);
    if (casal && form.conjuge_cpf && !cpfValido(form.conjuge_cpf)) { setErro('O CPF do cônjuge não é válido. Confira os números.'); return; }
    if (nova && equipe && !form.imobiliaria_id) { setErro('Escolha a imobiliária responsável pela pasta.'); return; }

    const vazioNulo = (s: string | null) => (s && s.trim() ? s.trim() : null);
    const dados = {
      comprador_nome: form.comprador_nome.trim(), comprador_cpf: soDigitos(form.comprador_cpf),
      comprador_nascimento: form.comprador_nascimento || null, comprador_telefone: vazioNulo(soDigitos(form.comprador_telefone || '')),
      comprador_email: vazioNulo(form.comprador_email), estado_civil: form.estado_civil,
      conjuge_nome: casal ? vazioNulo(form.conjuge_nome) : null,
      conjuge_cpf: casal ? vazioNulo(soDigitos(form.conjuge_cpf || '')) : null,
      conjuge_nascimento: casal ? form.conjuge_nascimento || null : null,
      conjuge_telefone: casal ? vazioNulo(soDigitos(form.conjuge_telefone || '')) : null,
      conjuge_email: casal ? vazioNulo(form.conjuge_email) : null,
      dados_bancarios: vazioNulo(form.dados_bancarios), observacoes: vazioNulo(form.observacoes),
    };
    setSalvando(true);
    if (nova) {
      const { data, error } = await supabase.from('pastas')
        .insert(equipe ? { ...dados, imobiliaria_id: form.imobiliaria_id } : { ...dados } as Record<string, unknown>).select('id').single();
      setSalvando(false);
      if (error || !data) { setErro('Não foi possível criar a pasta. Confira os dados e tente novamente.'); return; }
      ir(`/painel/pastas/${data.id}`);
    } else {
      const { error } = await supabase.from('pastas').update(dados).eq('id', id);
      setSalvando(false);
      if (error) { setErro('Não foi possível salvar as alterações.'); return; }
      setEditando(false); setAviso('Dados salvos.'); setRecarga((n) => n + 1);
    }
  };

  if (!nova && !pasta) return <section className="secao">{erro ? <p className="erro">{erro}</p> : <p className="vazio">Carregando…</p>}</section>;

  const casal = temConjuge(form.estado_civil);
  return (
    <section className="secao pasta">
      <button className="voltar" onClick={() => ir('/painel/pastas')}>‹ Pastas</button>
      <div className="secao-topo">
        <div>
          <h2>{nova ? 'Nova pasta' : pasta!.comprador_nome}</h2>
          {!nova && (
            <p className="sub">
              <span className="mono">{pasta!.codigo}</span>
              {equipe && pasta!.imobiliarias && <>, {pasta!.imobiliarias.nome}</>}
              , cadastrada{pasta!.criado_por && perfil.papel !== 'corretor' ? ` por ${pasta!.criado_por}` : ''} em {formatarData(pasta!.criada_em)}
            </p>
          )}
        </div>
        {!nova && <span className={`selo grande sp-${pasta!.status}`}>{rotuloPasta(pasta!.status)}</span>}
      </div>

      {!nova && equipe && <VincularUnidade pasta={pasta!} aoMudar={() => setRecarga((n) => n + 1)} />}
      {!nova && !equipe && pasta!.unidades && <p className="sub">Unidade vinculada: <strong>{pasta!.unidades.numero}</strong></p>}

      <form className="cartao" onSubmit={salvar}>
        <div className="cartao-topo">
          <h3>Dados do comprador</h3>
          {!nova && !editando && <button type="button" className="botao" onClick={() => setEditando(true)}>Editar dados</button>}
        </div>
        <fieldset disabled={!editando || salvando} className="grade-campos">
          {nova && equipe && (
            <label className="largo">Imobiliária responsável
              <select {...campo('imobiliaria_id')} required>
                <option value="">Escolha…</option>
                {imobiliarias.map((i) => <option key={i.id} value={i.id}>{i.nome}</option>)}
              </select>
            </label>
          )}
          <label className="largo">Nome completo<input {...campo('comprador_nome')} required maxLength={160} /></label>
          <label>CPF<input {...campo('comprador_cpf')} inputMode="numeric" required
            onChange={(e) => setForm((f) => ({ ...f, comprador_cpf: formatarCPF(e.target.value) }))} /></label>
          <label>Data de nascimento<input type="date" {...campo('comprador_nascimento')} /></label>
          <label>Telefone<input {...campo('comprador_telefone')} inputMode="tel"
            onChange={(e) => setForm((f) => ({ ...f, comprador_telefone: formatarTelefone(e.target.value) }))} /></label>
          <label>E-mail<input type="email" {...campo('comprador_email')} maxLength={160} /></label>
          <label>Estado civil
            <select {...campo('estado_civil')}>
              {ESTADOS_CIVIS.map((e) => <option key={e.valor} value={e.valor}>{e.rotulo}</option>)}
            </select>
          </label>
        </fieldset>

        {casal && (
          <>
            <h3>Cônjuge</h3>
            <fieldset disabled={!editando || salvando} className="grade-campos">
              <label className="largo">Nome completo<input {...campo('conjuge_nome')} maxLength={160} /></label>
              <label>CPF<input {...campo('conjuge_cpf')} inputMode="numeric"
                onChange={(e) => setForm((f) => ({ ...f, conjuge_cpf: formatarCPF(e.target.value) }))} /></label>
              <label>Data de nascimento<input type="date" {...campo('conjuge_nascimento')} /></label>
              <label>Telefone (opcional)<input {...campo('conjuge_telefone')} inputMode="tel"
                onChange={(e) => setForm((f) => ({ ...f, conjuge_telefone: formatarTelefone(e.target.value) }))} /></label>
              <label>E-mail (opcional)<input type="email" {...campo('conjuge_email')} maxLength={160} /></label>
            </fieldset>
          </>
        )}

        <h3>Complementares</h3>
        <fieldset disabled={!editando || salvando} className="grade-campos">
          <label className="largo">Dados bancários ou chave PIX<input {...campo('dados_bancarios')} maxLength={300} /></label>
          <label className="largo">Observações<textarea rows={2} {...campo('observacoes')} maxLength={1000} /></label>
        </fieldset>

        {erro && <p className="erro" role="alert">{erro}</p>}
        {aviso && <p className="ok" role="status">{aviso}</p>}
        {editando && (
          <div className="acoes">
            {!nova && <button type="button" className="botao" onClick={() => { setEditando(false); setRecarga((n) => n + 1); }}>Cancelar</button>}
            <button className="botao principal" disabled={salvando}>
              {salvando ? 'Salvando…' : nova ? 'Criar pasta e seguir para os documentos' : 'Salvar dados'}
            </button>
          </div>
        )}
      </form>

      {!nova && <Documentos pasta={pasta!} estadoCivil={pasta!.estado_civil} equipe={equipe} aoMudar={() => setRecarga((n) => n + 1)} />}
      {!nova && <HistoricoPasta pastaId={id} recarga={recarga} />}
    </section>
  );
}

// ---------------------------------------------------------------------
function VincularUnidade({ pasta, aoMudar }: { pasta: Pasta; aoMudar: () => void }) {
  const [unidades, setUnidades] = useState<{ id: string; numero: string }[]>([]);
  const [valor, setValor] = useState(pasta.unidade_id ?? '');
  const [erro, setErro] = useState('');
  useEffect(() => {
    supabase.from('unidades').select('id, numero').order('andar').order('posicao')
      .then(({ data }) => setUnidades((data as { id: string; numero: string }[]) ?? []));
  }, []);
  const salvar = async (novo: string) => {
    setValor(novo); setErro('');
    const { error } = await supabase.rpc('vincular_unidade', { p_pasta: pasta.id, p_unidade: novo || null });
    if (error) setErro('Não foi possível vincular a unidade.'); else aoMudar();
  };
  return (
    <div className="vinculo">
      <label>Unidade vinculada
        <select value={valor} onChange={(e) => salvar(e.target.value)}>
          <option value="">Nenhuma</option>
          {unidades.map((u) => <option key={u.id} value={u.id}>{u.numero}</option>)}
        </select>
      </label>
      {erro && <span className="erro">{erro}</span>}
    </div>
  );
}

// =====================================================================
// Documentos
// =====================================================================
interface Tipo { id: number; nome: string; pessoa: 'comprador' | 'conjuge' | 'geral'; obrigatorio_para: EstadoCivil[]; exibir_para: EstadoCivil[]; multiplo: boolean; ordem: number }
interface Documento {
  id: string; tipo_id: number; caminho: string; nome_arquivo: string; tamanho: number | null; status: StatusDocumento;
  motivo_recusa: string | null; atual: boolean; enviado_por: string | null; enviado_em: string;
  analisado_por: string | null; analisado_em: string | null;
}

const TIPOS_ACEITOS = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'];
const LIMITE = 15 * 1024 * 1024;
const PESSOAS: { valor: Tipo['pessoa']; titulo: string }[] = [
  { valor: 'comprador', titulo: 'Documentos do comprador' },
  { valor: 'conjuge', titulo: 'Documentos do cônjuge' },
  { valor: 'geral', titulo: 'Documentos complementares' },
];

function Documentos({ pasta, estadoCivil, equipe, aoMudar }: { pasta: Pasta; estadoCivil: EstadoCivil; equipe: boolean; aoMudar: () => void }) {
  const [tipos, setTipos] = useState<Tipo[]>([]);
  const [docs, setDocs] = useState<Documento[]>([]);
  const [recarga, setRecarga] = useState(0);

  useEffect(() => {
    supabase.from('tipos_documento').select('*').eq('ativo', true).order('ordem')
      .then(({ data }) => setTipos((data as Tipo[]) ?? []));
  }, []);
  useEffect(() => {
    supabase.from('documentos').select('*').eq('pasta_id', pasta.id).order('enviado_em', { ascending: false })
      .then(({ data }) => setDocs((data as Documento[]) ?? []));
  }, [pasta.id, recarga]);

  const atualizar = () => { setRecarga((n) => n + 1); aoMudar(); };
  const visiveis = tipos.filter((t) => (t.pessoa !== 'conjuge' || temConjuge(estadoCivil))
    && (t.exibir_para.length === 0 || t.exibir_para.includes(estadoCivil)));

  return (
    <div className="cartao">
      {PESSOAS.map((p) => {
        const lista = visiveis.filter((t) => t.pessoa === p.valor);
        if (!lista.length) return null;
        return (
          <div key={p.valor} className="bloco-docs">
            <h3>{p.titulo}</h3>
            <ul className="docs">
              {lista.map((t) => (
                <LinhaDocumento key={t.id} tipo={t} pasta={pasta} equipe={equipe}
                  obrigatorio={t.obrigatorio_para.includes(estadoCivil)}
                  docs={docs.filter((d) => d.tipo_id === t.id)} aoMudar={atualizar} />
              ))}
            </ul>
          </div>
        );
      })}
      <p className="dica">Arquivos aceitos: PDF, JPG, PNG ou HEIC, até 15 MB. Os arquivos ficam em armazenamento privado e só abrem para quem tem acesso à pasta.</p>
    </div>
  );
}

function LinhaDocumento({ tipo, pasta, equipe, obrigatorio, docs, aoMudar }: {
  tipo: Tipo; pasta: Pasta; equipe: boolean; obrigatorio: boolean; docs: Documento[]; aoMudar: () => void;
}) {
  const entrada = useRef<HTMLInputElement>(null);
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState('');
  const [recusando, setRecusando] = useState<string | null>(null);
  const [motivo, setMotivo] = useState('');
  const [verAnteriores, setVerAnteriores] = useState(false);

  const atuais = docs.filter((d) => d.atual);
  const anteriores = docs.filter((d) => !d.atual);
  const principal = atuais[0];
  const situacao: StatusDocumento | 'pendente' = tipo.multiplo ? (atuais.length ? 'enviado' : 'pendente') : principal?.status ?? 'pendente';
  const podeEnviar = equipe || tipo.multiplo || !principal || principal.status === 'enviado' || principal.status === 'recusado';

  const enviar = async (arquivo: File) => {
    setErro('');
    if (!TIPOS_ACEITOS.includes(arquivo.type) && !/\.(pdf|jpe?g|png|webp|heic|heif)$/i.test(arquivo.name)) {
      setErro('Formato não aceito. Envie PDF, JPG, PNG ou HEIC.'); return;
    }
    if (arquivo.size > LIMITE) { setErro('O arquivo passa de 15 MB. Reduza o tamanho e envie de novo.'); return; }
    setEnviando(true);
    const limpo = arquivo.name.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^\w.-]+/g, '_').slice(-80);
    const caminho = `${pasta.imobiliaria_id}/${pasta.id}/${crypto.randomUUID()}-${limpo}`;
    const up = await supabase.storage.from('documentos').upload(caminho, arquivo, { upsert: false, contentType: arquivo.type || undefined });
    if (up.error) { setEnviando(false); setErro('Não foi possível enviar o arquivo. Verifique a internet e tente de novo.'); return; }
    const { error } = await supabase.rpc('registrar_documento', {
      p_pasta: pasta.id, p_tipo: tipo.id, p_caminho: caminho, p_nome: arquivo.name, p_tamanho: arquivo.size, p_mime: arquivo.type || null,
    });
    setEnviando(false);
    if (error) {
      setErro(error.message.includes('DOCUMENTO_BLOQUEADO')
        ? 'Este documento já está em análise ou aprovado e não pode ser substituído.'
        : 'O arquivo subiu, mas não foi possível registrá-lo. Tente de novo.');
      return;
    }
    aoMudar();
  };

  const abrir = async (d: Documento) => {
    const janela = window.open('', '_blank');
    const { data, error } = await supabase.storage.from('documentos').createSignedUrl(d.caminho, 120);
    if (error || !data) { janela?.close(); setErro('Não foi possível abrir o arquivo.'); return; }
    if (janela) janela.location.href = data.signedUrl; else window.location.href = data.signedUrl;
  };

  const analisar = async (d: Documento, novo: StatusDocumento, mot?: string) => {
    setErro('');
    const { error } = await supabase.rpc('analisar_documento', { p_documento: d.id, p_status: novo, p_motivo: mot ?? null });
    if (error) { setErro(error.message.includes('MOTIVO') ? 'Informe o motivo da recusa.' : 'Não foi possível salvar a análise.'); return; }
    setRecusando(null); setMotivo(''); aoMudar();
  };

  return (
    <li className={`doc sd-${situacao}`}>
      <div className="doc-topo">
        <div>
          <strong>{tipo.nome}</strong>
          {obrigatorio ? <span className="obrig">Obrigatório</span> : <span className="opc">Opcional</span>}
        </div>
        <span className={`selo sd-${situacao}`}>{ROTULO_DOC[situacao]}</span>
      </div>

      {atuais.map((d) => (
        <div key={d.id} className="arquivo">
          <button type="button" className="link" onClick={() => abrir(d)}>{d.nome_arquivo}</button>
          <span className="meta">{formatarTamanho(d.tamanho)}, enviado por {d.enviado_por ?? '—'} em {formatarDataHora(d.enviado_em)}</span>
          {tipo.multiplo && <span className={`selo sd-${d.status}`}>{ROTULO_DOC[d.status]}</span>}
          {d.status === 'recusado' && d.motivo_recusa && <p className="recusa">Motivo da recusa: {d.motivo_recusa}</p>}
          {d.analisado_por && d.status !== 'recusado' && d.status !== 'enviado' && (
            <span className="meta">{ROTULO_DOC[d.status]} por {d.analisado_por} em {formatarDataHora(d.analisado_em!)}</span>
          )}
          {equipe && (
            <div className="analise">
              {d.status !== 'em_analise' && d.status !== 'aprovado' && <button type="button" className="botao pequeno" onClick={() => analisar(d, 'em_analise')}>Em análise</button>}
              {d.status !== 'aprovado' && <button type="button" className="botao pequeno ok" onClick={() => analisar(d, 'aprovado')}>Aprovar</button>}
              {d.status !== 'recusado' && <button type="button" className="botao pequeno recusar" onClick={() => setRecusando(d.id)}>Recusar</button>}
            </div>
          )}
          {recusando === d.id && (
            <div className="recusar-form">
              <input autoFocus placeholder="Motivo da recusa (a imobiliária vai ver)" value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={300} />
              <button type="button" className="botao pequeno recusar" onClick={() => analisar(d, 'recusado', motivo)}>Confirmar recusa</button>
              <button type="button" className="botao pequeno" onClick={() => { setRecusando(null); setMotivo(''); }}>Cancelar</button>
            </div>
          )}
        </div>
      ))}

      {podeEnviar && (
        <>
          <input ref={entrada} type="file" hidden accept=".pdf,.jpg,.jpeg,.png,.webp,.heic,.heif,application/pdf,image/*"
            onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) enviar(f); }} />
          <button type="button" className="botao pequeno" disabled={enviando} onClick={() => entrada.current?.click()}>
            {enviando ? 'Enviando…' : tipo.multiplo ? 'Adicionar arquivo' : principal ? 'Substituir arquivo' : 'Enviar arquivo'}
          </button>
        </>
      )}
      {erro && <p className="erro">{erro}</p>}

      {anteriores.length > 0 && (
        <div className="anteriores">
          <button type="button" className="link" onClick={() => setVerAnteriores((v) => !v)}>
            {verAnteriores ? 'Ocultar' : 'Ver'} versões anteriores ({anteriores.length})
          </button>
          {verAnteriores && (
            <ul>
              {anteriores.map((d) => (
                <li key={d.id}>
                  <button type="button" className="link" onClick={() => abrir(d)}>{d.nome_arquivo}</button>{' '}
                  <span className="meta">{ROTULO_DOC[d.status]}, {formatarDataHora(d.enviado_em)}{d.motivo_recusa ? `, motivo: ${d.motivo_recusa}` : ''}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </li>
  );
}

// ---------------------------------------------------------------------
function HistoricoPasta({ pastaId, recarga }: { pastaId: string; recarga: number }) {
  const [itens, setItens] = useState<{ id: number; acao: string; detalhes: Record<string, unknown> | null; usuario_email: string | null; criado_em: string }[]>([]);
  useEffect(() => {
    supabase.from('historico_pastas').select('*').eq('pasta_id', pastaId).order('criado_em', { ascending: false }).limit(50)
      .then(({ data }) => setItens((data as typeof itens) ?? []));
  }, [pastaId, recarga]);
  if (!itens.length) return null;
  const descrever = (d: Record<string, unknown> | null) => {
    if (!d) return '';
    if (Array.isArray(d.campos)) return `Campos: ${(d.campos as string[]).map((c) => c.replace(/_/g, ' ')).join(', ')}`;
    return [d.documento, d.arquivo, d.unidade && `Unidade ${d.unidade}`, d.motivo && `Motivo: ${d.motivo}`].filter(Boolean).join('; ');
  };
  return (
    <div className="cartao">
      <h3>Histórico da pasta</h3>
      <ol className="historico">
        {itens.map((h) => (
          <li key={h.id}>
            <strong>{h.acao}</strong>
            {h.detalhes && <span className="motivo">{descrever(h.detalhes)}</span>}
            <span className="quem">{h.usuario_email}, {formatarDataHora(h.criado_em)}</span>
          </li>
        ))}
      </ol>
    </div>
  );
}
