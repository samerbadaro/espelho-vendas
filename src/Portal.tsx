import { useCallback, useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react';
import {
  ArrowLeft, BookOpen, Calculator, Download, ExternalLink, FileText, FolderArchive, Image, LifeBuoy, Link2,
  Megaphone, Pencil, Plus, Rotate3d, Ruler, Sofa, Trash2, Upload, Video, X,
} from 'lucide-react';
import { zipSync } from 'fflate';
import { supabase } from './dados';
import { ir, type Perfil } from './util';
import { useDialogos } from './ui';

interface Item {
  id: string; categoria: string; titulo: string; descricao: string | null; link: string | null;
  caminho: string | null; nome_arquivo: string | null; tamanho: number | null; tipo_mime: string | null; criado_em: string;
}

interface Categoria { valor: string; rotulo: string; icone: ReactNode; galeria?: boolean }

// Em ordem alfabética pelo nome (a ordenação é refeita na tela, com acentos tratados)
const CATEGORIAS: Categoria[] = ([
  { valor: 'book', rotulo: 'Book e apresentações', icone: <BookOpen size={22} /> },
  { valor: 'ficha_tecnica', rotulo: 'Ficha técnica', icone: <FileText size={22} /> },
  { valor: 'fotos_decorado', rotulo: 'Fotos do decorado', icone: <Sofa size={22} />, galeria: true },
  { valor: 'imagens', rotulo: 'Imagens do empreendimento', icone: <Image size={22} />, galeria: true },
  { valor: 'materiais_apoio', rotulo: 'Materiais de apoio', icone: <LifeBuoy size={22} /> },
  { valor: 'redes_sociais', rotulo: 'Material para redes sociais', icone: <Megaphone size={22} />, galeria: true },
  { valor: 'plantas', rotulo: 'Plantas', icone: <Ruler size={22} />, galeria: true },
  { valor: 'simulador', rotulo: 'Simulador', icone: <Calculator size={22} /> },
  { valor: 'tour_virtual', rotulo: 'Tour virtual', icone: <Rotate3d size={22} /> },
  { valor: 'videos', rotulo: 'Vídeos', icone: <Video size={22} /> },
] as Categoria[]).sort((a, b) => a.rotulo.localeCompare(b.rotulo, 'pt-BR', { sensitivity: 'base' }));

const ERROS: Record<string, string> = {
  SEM_PERMISSAO: 'Só a Sec. Vendas e o administrador podem alterar o portal.',
  TITULO_OBRIGATORIO: 'Informe um título.',
  ARQUIVO_OU_LINK: 'Envie um arquivo ou informe um link.',
  LINK_INVALIDO: 'O link precisa começar com http:// ou https://.',
};

const tamanho = (b: number | null) => {
  if (!b) return '';
  if (b < 1024 * 1024) return `${Math.max(1, Math.round(b / 1024))} KB`;
  if (b < 1024 * 1024 * 1024) return `${(b / 1024 / 1024).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} MB`;
  return `${(b / 1024 / 1024 / 1024).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} GB`;
};
const ehImagem = (i: Item) => !!i.tipo_mime?.startsWith('image/');
const extensao = (nome: string | null) => (nome?.match(/\.([a-z0-9]{1,5})$/i)?.[1] ?? '').toUpperCase();
const nomeSeguro = (n: string) => n.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/-+/g, '-').slice(-80);
const semExtensao = (n: string) => n.replace(/\.[^.]+$/, '').replace(/[_-]+/g, ' ').trim();

export function Portal({ perfil, categoria }: { perfil: Perfil; categoria?: string }) {
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const [itens, setItens] = useState<Item[] | null>(null);

  const carregar = useCallback(async () => {
    const { data } = await supabase.from('portal_itens').select('*').order('titulo');
    setItens((data as Item[]) ?? []);
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const cat = CATEGORIAS.find((c) => c.valor === categoria);
  if (cat) return <CategoriaPortal cat={cat} itens={(itens ?? []).filter((i) => i.categoria === cat.valor)} carregando={itens == null} equipe={equipe} recarregar={carregar} />;

  const contagem = (v: string) => (itens ?? []).filter((i) => i.categoria === v).length;
  return (
    <section className="secao">
      <div className="secao-topo">
        <div>
          <h2>Portal do Corretor</h2>
          <p className="sub">{equipe ? 'Materiais de venda do empreendimento. Abra uma categoria para adicionar arquivos ou links.' : 'Materiais de venda do empreendimento para visualizar e baixar.'}</p>
        </div>
      </div>
      <div className="portal-grade">
        {CATEGORIAS.map((c) => {
          const n = contagem(c.valor);
          return (
            <button key={c.valor} className="portal-categoria" onClick={() => ir(`/painel/portal/${c.valor}`)}>
              <span className="portal-icone">{c.icone}</span>
              <span className="portal-nome">{c.rotulo}</span>
              <span className="portal-qtd">{itens == null ? '…' : n === 0 ? 'Nenhum item' : `${n} ${n === 1 ? 'item' : 'itens'}`}</span>
            </button>
          );
        })}
      </div>
    </section>
  );
}

function CategoriaPortal({ cat, itens, carregando, equipe, recarregar }: {
  cat: Categoria; itens: Item[]; carregando: boolean; equipe: boolean; recarregar: () => void;
}) {
  const { confirmar, avisar } = useDialogos();
  const [miniaturas, setMiniaturas] = useState<Record<string, string>>({});
  const [adicionando, setAdicionando] = useState(false);
  const [editando, setEditando] = useState<Item | null>(null);
  const [baixando, setBaixando] = useState('');

  const imagens = useMemo(() => itens.filter((i) => i.caminho && ehImagem(i)), [itens]);
  useEffect(() => {
    if (!imagens.length) return;
    supabase.storage.from('portal').createSignedUrls(imagens.map((i) => i.caminho!), 3600).then(({ data }) => {
      const m: Record<string, string> = {};
      (data ?? []).forEach((d, k) => { if (d.signedUrl) m[imagens[k].id] = d.signedUrl; });
      setMiniaturas(m);
    });
  }, [imagens]);

  const baixar = async (i: Item) => {
    if (i.link) { window.open(i.link, '_blank', 'noopener'); return; }
    const { data, error } = await supabase.storage.from('portal').createSignedUrl(i.caminho!, 120, { download: i.nome_arquivo ?? true });
    if (error || !data) { avisar('Não foi possível baixar o arquivo.', 'erro'); return; }
    const a = document.createElement('a'); a.href = data.signedUrl; a.rel = 'noopener'; a.click();
  };

  const abrir = async (i: Item) => {
    if (i.link) { window.open(i.link, '_blank', 'noopener'); return; }
    const { data } = await supabase.storage.from('portal').createSignedUrl(i.caminho!, 600);
    if (data) window.open(data.signedUrl, '_blank', 'noopener');
  };

  const arquivos = itens.filter((i) => i.caminho);
  const baixarTudo = async () => {
    const conteudo: Record<string, [Uint8Array, { level: 0 }]> = {};
    const usados = new Set<string>();
    try {
      const { data } = await supabase.storage.from('portal').createSignedUrls(arquivos.map((i) => i.caminho!), 600);
      for (let k = 0; k < arquivos.length; k++) {
        setBaixando(`Baixando ${k + 1} de ${arquivos.length}…`);
        const url = data?.[k]?.signedUrl;
        if (!url) throw new Error();
        const resp = await fetch(url);
        if (!resp.ok) throw new Error();
        let nome = arquivos[k].nome_arquivo || `${arquivos[k].titulo}.${extensao(arquivos[k].caminho).toLowerCase()}`;
        for (let n = 2; usados.has(nome); n++) nome = nome.replace(/(\.[^.]+)?$/, `_${n}$1`);
        usados.add(nome);
        conteudo[nome] = [new Uint8Array(await resp.arrayBuffer()), { level: 0 }];
      }
    } catch {
      setBaixando(''); avisar('A conexão falhou durante o download. Tente novamente.', 'erro'); return;
    }
    const zip = zipSync(conteudo);
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([zip], { type: 'application/zip' }));
    a.download = `${nomeSeguro(cat.rotulo).toLowerCase()}.zip`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    setBaixando('');
  };

  const remover = async (i: Item) => {
    if (!(await confirmar({ titulo: `Remover "${i.titulo}"?`, texto: 'Corretores e imobiliárias deixam de ver este item.', confirmar: 'Remover', perigo: true }))) return;
    const { data, error } = await supabase.rpc('remover_item_portal', { p_id: i.id });
    if (error) { avisar(ERROS[error.message] ?? 'Não foi possível remover.', 'erro'); return; }
    if (data) await supabase.storage.from('portal').remove([data as string]);
    avisar('Item removido.'); recarregar();
  };

  const acoes = (i: Item) => (
    <div className="portal-acoes">
      {i.link ? (
        <button className="botao pequeno principal" onClick={() => baixar(i)}><ExternalLink size={14} /> Abrir</button>
      ) : (
        <>
          <button className="botao pequeno" onClick={() => abrir(i)}>Visualizar</button>
          <button className="botao pequeno principal" onClick={() => baixar(i)}><Download size={14} /> Baixar</button>
        </>
      )}
      {equipe && (
        <>
          <button className="icone-botao" onClick={() => setEditando(i)} aria-label={`Editar ${i.titulo}`} title="Editar"><Pencil size={15} /></button>
          <button className="icone-botao" onClick={() => remover(i)} aria-label={`Remover ${i.titulo}`} title="Remover"><Trash2 size={15} /></button>
        </>
      )}
    </div>
  );

  const comImagem = itens.filter((i) => miniaturas[i.id]);
  const semImagem = itens.filter((i) => !miniaturas[i.id]);

  return (
    <section className="secao">
      <button className="voltar" onClick={() => ir('/painel/portal')}><ArrowLeft size={16} /> Portal do Corretor</button>
      <div className="secao-topo">
        <div className="titulo-categoria">
          <span className="portal-icone">{cat.icone}</span>
          <h2>{cat.rotulo}</h2>
        </div>
        <div className="acoes-topo">
          {arquivos.length > 1 && (
            <button className="botao" onClick={baixarTudo} disabled={!!baixando}><FolderArchive size={16} /> {baixando || 'Baixar tudo (.zip)'}</button>
          )}
          {equipe && <button className="botao principal" onClick={() => setAdicionando(true)}><Plus size={16} /> Adicionar</button>}
        </div>
      </div>

      {carregando ? <p className="vazio">Carregando…</p> : itens.length === 0 ? (
        <div className="cartao vazio-grande">
          <p>{equipe ? 'Nenhum material nesta categoria ainda. Use "Adicionar" para enviar arquivos ou incluir links.' : 'Nenhum material disponível nesta categoria ainda.'}</p>
        </div>
      ) : (
        <>
          {comImagem.length > 0 && (
            <div className="portal-galeria">
              {comImagem.map((i) => (
                <figure key={i.id} className="portal-foto">
                  <button className="portal-miniatura" onClick={() => abrir(i)} aria-label={`Ver ${i.titulo} em tamanho real`}>
                    <img src={miniaturas[i.id]} alt={i.titulo} loading="lazy" />
                  </button>
                  <figcaption>
                    <strong>{i.titulo}</strong>
                    <span>{[extensao(i.nome_arquivo), tamanho(i.tamanho)].filter(Boolean).join(' · ')}</span>
                  </figcaption>
                  {acoes(i)}
                </figure>
              ))}
            </div>
          )}
          {semImagem.length > 0 && (
            <ul className="portal-lista">
              {semImagem.map((i) => (
                <li key={i.id}>
                  <span className="portal-tipo">{i.link ? <Link2 size={18} /> : extensao(i.nome_arquivo) || <FileText size={18} />}</span>
                  <div className="portal-info">
                    <strong>{i.titulo}</strong>
                    {i.descricao && <span>{i.descricao}</span>}
                    <small>{i.link ? new URL(i.link).hostname.replace(/^www\./, '') : tamanho(i.tamanho)}</small>
                  </div>
                  {acoes(i)}
                </li>
              ))}
            </ul>
          )}
        </>
      )}

      {adicionando && <AdicionarItem cat={cat} aoFechar={() => setAdicionando(false)} aoSalvar={() => { setAdicionando(false); recarregar(); }} />}
      {editando && <EditarItem item={editando} aoFechar={() => setEditando(null)} aoSalvar={() => { setEditando(null); recarregar(); }} />}
    </section>
  );
}

function AdicionarItem({ cat, aoFechar, aoSalvar }: { cat: Categoria; aoFechar: () => void; aoSalvar: () => void }) {
  const { avisar } = useDialogos();
  const linkPrimeiro = cat.valor === 'tour_virtual' || cat.valor === 'videos' || cat.valor === 'simulador';
  const [modo, setModo] = useState<'arquivo' | 'link'>(linkPrimeiro ? 'link' : 'arquivo');
  const [arquivos, setArquivos] = useState<File[]>([]);
  const [titulo, setTitulo] = useState('');
  const [descricao, setDescricao] = useState('');
  const [link, setLink] = useState('');
  const [erro, setErro] = useState('');
  const [progresso, setProgresso] = useState('');

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && !progresso && aoFechar();
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [aoFechar, progresso]);

  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (modo === 'link') {
      const { error } = await supabase.rpc('adicionar_item_portal', { p_categoria: cat.valor, p_titulo: titulo, p_descricao: descricao, p_link: link });
      if (error) { setErro(ERROS[error.message] ?? 'Não foi possível salvar.'); return; }
      avisar('Link adicionado.'); aoSalvar(); return;
    }
    if (!arquivos.length) { setErro('Escolha pelo menos um arquivo.'); return; }
    let ok = 0;
    for (let k = 0; k < arquivos.length; k++) {
      const f = arquivos[k];
      setProgresso(`Enviando ${k + 1} de ${arquivos.length}: ${f.name}`);
      const caminho = `${cat.valor}/${crypto.randomUUID()}-${nomeSeguro(f.name)}`;
      const up = await supabase.storage.from('portal').upload(caminho, f, { contentType: f.type || undefined, upsert: false });
      if (up.error) {
        setErro(`Não foi possível enviar "${f.name}". ${/size|large|exceed/i.test(up.error.message) ? 'O arquivo passa do limite de tamanho do armazenamento.' : 'Tente novamente.'}`);
        break;
      }
      const t = arquivos.length === 1 && titulo.trim() ? titulo : semExtensao(f.name);
      const { error } = await supabase.rpc('adicionar_item_portal', {
        p_categoria: cat.valor, p_titulo: t, p_descricao: arquivos.length === 1 ? descricao : null,
        p_caminho: caminho, p_nome_arquivo: f.name, p_tamanho: f.size, p_tipo: f.type || null,
      });
      if (error) { await supabase.storage.from('portal').remove([caminho]); setErro(ERROS[error.message] ?? 'Não foi possível salvar.'); break; }
      ok++;
    }
    setProgresso('');
    if (ok) avisar(`${ok} ${ok === 1 ? 'arquivo adicionado' : 'arquivos adicionados'}.`);
    if (ok === arquivos.length) aoSalvar();
    else setArquivos((l) => l.slice(ok));
  };

  return (
    <div className="fundo-dialogo" onClick={() => !progresso && aoFechar()}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="add-titulo" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <div className="dialogo-topo">
          <h2 id="add-titulo">Adicionar em {cat.rotulo}</h2>
          <button type="button" className="icone-botao" onClick={aoFechar} disabled={!!progresso} aria-label="Fechar"><X size={18} /></button>
        </div>
        <div className="abas-modo" role="tablist">
          <button type="button" role="tab" aria-selected={modo === 'arquivo'} className={modo === 'arquivo' ? 'ativa' : ''} onClick={() => setModo('arquivo')}><Upload size={15} /> Arquivos</button>
          <button type="button" role="tab" aria-selected={modo === 'link'} className={modo === 'link' ? 'ativa' : ''} onClick={() => setModo('link')}><Link2 size={15} /> Link</button>
        </div>

        {modo === 'arquivo' ? (
          <div className="campos">
            <label className="largo">Arquivos
              <input type="file" multiple onChange={(e) => setArquivos(Array.from(e.target.files ?? []))} />
              <small>Pode escolher vários de uma vez. Cada arquivo vira um item, com o nome do arquivo como título.</small>
            </label>
            {arquivos.length === 1 && (
              <>
                <label className="largo">Título<input value={titulo} onChange={(e) => setTitulo(e.target.value)} placeholder={semExtensao(arquivos[0].name)} maxLength={120} /></label>
                <label className="largo">Descrição (opcional)<input value={descricao} onChange={(e) => setDescricao(e.target.value)} maxLength={200} /></label>
              </>
            )}
            {arquivos.length > 1 && <p className="dica largo">{arquivos.length} arquivos selecionados.</p>}
          </div>
        ) : (
          <div className="campos">
            <label className="largo">Título<input value={titulo} onChange={(e) => setTitulo(e.target.value)} maxLength={120} placeholder={cat.valor === 'tour_virtual' ? 'Tour 360º do decorado' : ''} /></label>
            <label className="largo">Link<input value={link} onChange={(e) => setLink(e.target.value)} type="url" placeholder="https://" /></label>
            <label className="largo">Descrição (opcional)<input value={descricao} onChange={(e) => setDescricao(e.target.value)} maxLength={200} /></label>
            <p className="dica largo">Use links para vídeos (YouTube, Vimeo), tour virtual, simulador on-line ou pastas no Google Drive.</p>
          </div>
        )}

        {progresso && <p className="dica">{progresso}</p>}
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar} disabled={!!progresso}>Cancelar</button>
          <button className="botao principal" disabled={!!progresso}>{progresso ? 'Enviando…' : 'Adicionar'}</button>
        </div>
      </form>
    </div>
  );
}

function EditarItem({ item, aoFechar, aoSalvar }: { item: Item; aoFechar: () => void; aoSalvar: () => void }) {
  const [titulo, setTitulo] = useState(item.titulo);
  const [descricao, setDescricao] = useState(item.descricao ?? '');
  const [erro, setErro] = useState('');
  const salvar = async (e: FormEvent) => {
    e.preventDefault();
    const { error } = await supabase.rpc('editar_item_portal', { p_id: item.id, p_titulo: titulo, p_descricao: descricao });
    if (error) { setErro(ERROS[error.message] ?? 'Não foi possível salvar.'); return; }
    aoSalvar();
  };
  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="edit-item" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="edit-item">Editar item</h2>
        <div className="campos">
          <label className="largo">Título<input value={titulo} onChange={(e) => setTitulo(e.target.value)} maxLength={120} autoFocus /></label>
          <label className="largo">Descrição<input value={descricao} onChange={(e) => setDescricao(e.target.value)} maxLength={200} /></label>
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
