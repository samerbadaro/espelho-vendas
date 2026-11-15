import { useEffect, useRef, useState, type FormEvent } from 'react';
import { DadosComerciais, GestaoEmpreendimentos } from './Empreendimentos';
import { ImageUp, Trash2 } from 'lucide-react';
import { supabase } from './dados';
import { useMarca, useDialogos, aplicarMarca, textoSobre, FONTES, type Marca } from './ui';

type Campos = Pick<Marca, 'nome_empreendimento' | 'cidade' | 'cor_primaria' | 'cor_destaque' | 'cor_apoio' | 'fonte' | 'logo_url' | 'logo_escuro_url' | 'imagem_login_url' | ChaveModulo>;
type ChaveModulo = 'modulo_pastas' | 'modulo_funil' | 'modulo_portal' | 'modulo_rodadas' | 'modulo_meeting' | 'modulo_tv' | 'modulo_cadastro' | 'modulo_espelho_parceiros';

const MODULOS: { k: ChaveModulo; titulo: string; texto: string; depende?: ChaveModulo }[] = [
  { k: 'modulo_pastas', titulo: 'Pastas de compradores', texto: 'Desligado, o sistema fica só com o espelho e o status das unidades. Pastas já criadas continuam guardadas.' },
  { k: 'modulo_funil', titulo: 'Funil de vendas', texto: 'Quadro com as reservas e vendas por etapa. Depende das Pastas.', depende: 'modulo_pastas' },
  { k: 'modulo_portal', titulo: 'Portal do Corretor', texto: 'Materiais de venda para imobiliárias e corretores baixarem.' },
  { k: 'modulo_rodadas', titulo: 'Rodadas de negócios', texto: 'Inscrição de clientes pelos corretores nas rodadas.' },
  { k: 'modulo_meeting', titulo: 'Meeting', texto: 'Lista de convidados e confirmação de presença na entrada do evento.' },
  { k: 'modulo_espelho_parceiros', titulo: 'Espelho para imobiliárias e corretores', texto: 'Desligado, só a equipe vê o espelho dentro do painel. O link público é controlado na tela Espelho.' },
  { k: 'modulo_tv', titulo: 'Modo TV', texto: 'Tela cheia do espelho para TVs do plantão e do stand.' },
  { k: 'modulo_cadastro', titulo: 'Cadastro de imobiliárias pelo link', texto: 'Página /cadastro, onde a imobiliária pede o acesso. Desligado, só você cria os logins.' },
];
const HEX = /^#[0-9A-Fa-f]{6}$/;

/** Configuração do empreendimento (somente administrador): nome, marca e módulos. */
export function Empreendimento() {
  const { marca, recarregar } = useMarca();
  const { avisar } = useDialogos();
  const [f, setF] = useState<Campos | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (marca.nome_empreendimento && !f) setF({
      nome_empreendimento: marca.nome_empreendimento, cidade: marca.cidade ?? '', cor_primaria: marca.cor_primaria,
      cor_destaque: marca.cor_destaque, cor_apoio: marca.cor_apoio, fonte: marca.fonte, logo_url: marca.logo_url, logo_escuro_url: marca.logo_escuro_url,
      imagem_login_url: marca.imagem_login_url,
      ...Object.fromEntries(MODULOS.map((m) => [m.k, marca[m.k] ?? true])) as Pick<Marca, ChaveModulo>,
    });
  }, [marca, f]);

  // pré-visualização ao vivo das cores
  useEffect(() => {
    if (f && HEX.test(f.cor_primaria) && HEX.test(f.cor_destaque) && HEX.test(f.cor_apoio)) aplicarMarca(f);
    return () => aplicarMarca(marca);
  }, [f?.cor_primaria, f?.cor_destaque, f?.cor_apoio, f?.fonte]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!f) return <section className="secao"><p className="vazio">Carregando…</p></section>;
  const muda = (k: keyof Campos, v: unknown) => setF((x) => (x ? { ...x, [k]: v } : x));

  const salvar = async (e: FormEvent) => {
    e.preventDefault();
    if (f.nome_empreendimento.trim().length < 2) { avisar('Informe o nome do empreendimento.', 'erro'); return; }
    if (!HEX.test(f.cor_primaria) || !HEX.test(f.cor_destaque) || !HEX.test(f.cor_apoio)) { avisar('As cores precisam estar no formato #RRGGBB.', 'erro'); return; }
    setSalvando(true);
    const { error } = await supabase.from('config').update({
      nome_empreendimento: f.nome_empreendimento.trim(), cidade: f.cidade?.trim() || null,
      cor_primaria: f.cor_primaria, cor_destaque: f.cor_destaque, cor_apoio: f.cor_apoio, fonte: f.fonte, logo_url: f.logo_url,
      logo_escuro_url: f.logo_escuro_url, imagem_login_url: f.imagem_login_url,
      ...Object.fromEntries(MODULOS.map((m) => [m.k, f[m.k]])), atualizado_em: new Date().toISOString(),
    }).eq('empreendimento_id', marca.empreendimento_id ?? '');
    setSalvando(false);
    if (error) { avisar('Não foi possível salvar. Tente novamente.', 'erro'); return; }
    avisar('Empreendimento atualizado.');
    recarregar();
  };

  return (
    <section className="secao">
      <div className="secao-topo">
        <div><h2>Empreendimentos</h2><p className="sub">Cadastro dos empreendimentos e, abaixo, nome, identidade visual, módulos e dados comerciais do empreendimento atual ({f.nome_empreendimento}).</p></div>
      </div>
      <GestaoEmpreendimentos />
      <form onSubmit={salvar}>
        <div className="cartao">
          <h3>Dados</h3>
          <div className="grade-campos">
            <label>Nome do empreendimento<input value={f.nome_empreendimento} onChange={(e) => muda('nome_empreendimento', e.target.value)} maxLength={80} required /></label>
            <label>Cidade<input value={f.cidade ?? ''} onChange={(e) => muda('cidade', e.target.value)} maxLength={60} placeholder="Ex.: Rio Verde, GO" /></label>
          </div>
        </div>

        <div className="cartao">
          <h3>Identidade visual</h3>
          <div className="grade-campos">
            <CampoCor rotulo="Cor principal (menu e botões)" valor={f.cor_primaria} aoMudar={(v) => muda('cor_primaria', v)} />
            <CampoCor rotulo="Cor de destaque (detalhes e realces)" valor={f.cor_destaque} aoMudar={(v) => muda('cor_destaque', v)} />
            <CampoCor rotulo="Cor de apoio (faixas do prédio e fundos)" valor={f.cor_apoio} aoMudar={(v) => muda('cor_apoio', v)} />
            <label>Fonte
              <select value={f.fonte} onChange={(e) => muda('fonte', e.target.value)}>
                {[...new Set([f.fonte, ...FONTES])].map((n) => <option key={n} value={n}>{n}</option>)}
              </select>
            </label>
          </div>
          <div className="grade-imagens">
            <EnvioImagem rotulo="Logo para fundo claro" dica="PNG ou SVG com fundo transparente" valor={f.logo_url} aoMudar={(v) => muda('logo_url', v)} fundo="#FFFFFF" />
            <EnvioImagem rotulo="Logo para fundo escuro" dica="Usado no menu, no login e na TV" valor={f.logo_escuro_url} aoMudar={(v) => muda('logo_escuro_url', v)} fundo={f.cor_primaria} />
            <EnvioImagem rotulo="Imagem da tela de login" dica="Perspectiva da fachada ou do rooftop, na horizontal" valor={f.imagem_login_url} aoMudar={(v) => muda('imagem_login_url', v)} capa />
          </div>
        </div>

        <div className="cartao">
          <h3>Módulos</h3>
          <p className="sub">Desligar um módulo só tira ele do menu. Nenhum dado é apagado, e ao religar tudo volta como estava.</p>
          <div className="lista-modulos">
            {MODULOS.map((m) => {
              const bloqueado = m.depende && !f[m.depende];
              return (
                <label key={m.k} className={`interruptor${bloqueado ? ' desativado' : ''}`}>
                  <input type="checkbox" checked={f[m.k] && !bloqueado} disabled={!!bloqueado} onChange={(e) => muda(m.k, e.target.checked)} />
                  <span className="trilho" aria-hidden="true" />
                  <span><strong>{m.titulo}</strong><br /><span className="sub">{bloqueado ? 'Ligue as Pastas de compradores para usar este módulo.' : m.texto}</span></span>
                </label>
              );
            })}
          </div>
        </div>

        <div className="acoes"><button className="botao principal" disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar alterações'}</button></div>
      </form>
      <DadosComerciais />
    </section>
  );
}

function CampoCor({ rotulo, valor, aoMudar }: { rotulo: string; valor: string; aoMudar: (v: string) => void }) {
  return (
    <label>{rotulo}
      <span className="campo-cor">
        <input type="color" value={HEX.test(valor) ? valor : '#000000'} onChange={(e) => aoMudar(e.target.value.toUpperCase())} aria-label={rotulo} />
        <input value={valor} onChange={(e) => aoMudar(e.target.value)} maxLength={7} />
        <span className="amostra-texto" style={{ background: HEX.test(valor) ? valor : undefined, color: HEX.test(valor) ? textoSobre(valor) : undefined }}>Aa</span>
      </span>
    </label>
  );
}

export function EnvioImagem({ rotulo, dica, valor, aoMudar, fundo, capa }: {
  rotulo: string; dica: string; valor: string | null; aoMudar: (v: string | null) => void; fundo?: string; capa?: boolean;
}) {
  const entrada = useRef<HTMLInputElement>(null);
  const { avisar } = useDialogos();
  const [enviando, setEnviando] = useState(false);
  const enviar = async (arq: File) => {
    if (!/^image\/(png|jpeg|webp|svg\+xml)$/.test(arq.type)) { avisar('Envie PNG, JPG, WEBP ou SVG.', 'erro'); return; }
    if (arq.size > 5 * 1024 * 1024) { avisar('A imagem passa de 5 MB.', 'erro'); return; }
    setEnviando(true);
    const ext = arq.name.split('.').pop()?.toLowerCase() || 'png';
    const caminho = `${crypto.randomUUID()}.${ext}`;
    const { error } = await supabase.storage.from('marca').upload(caminho, arq, { contentType: arq.type, upsert: false });
    setEnviando(false);
    if (error) { avisar('Não foi possível enviar a imagem.', 'erro'); return; }
    aoMudar(supabase.storage.from('marca').getPublicUrl(caminho).data.publicUrl);
  };
  return (
    <div className="envio-imagem">
      <span className="rotulo">{rotulo}</span>
      <div className={`previa${capa ? ' capa' : ''}`} style={{ background: fundo }}>
        {valor ? <img src={valor} alt="" /> : <span className="sub">Sem imagem</span>}
      </div>
      <span className="dica">{dica}</span>
      <div className="envio-acoes">
        <input ref={entrada} type="file" hidden accept="image/png,image/jpeg,image/webp,image/svg+xml"
          onChange={(e) => { const a = e.target.files?.[0]; e.target.value = ''; if (a) enviar(a); }} />
        <button type="button" className="botao pequeno" disabled={enviando} onClick={() => entrada.current?.click()}>
          <ImageUp size={15} /> {enviando ? 'Enviando…' : valor ? 'Trocar' : 'Enviar'}
        </button>
        {valor && <button type="button" className="botao pequeno" onClick={() => aoMudar(null)}><Trash2 size={15} /> Remover</button>}
      </div>
    </div>
  );
}
