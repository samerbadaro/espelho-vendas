// Manual do sistema: mostra só os capítulos dos módulos visíveis para o perfil,
// e dentro de cada capítulo só o que vale para o perfil. Vídeo opcional por capítulo.
import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import { Printer, Search, Sparkles, Video } from 'lucide-react';
import { supabase, formatarDataHora } from '../dados';
import { useDialogos } from '../ui';
import { CAPITULOS, NOVIDADES, REVISAO_MANUAL, ROTULO_PAPEL, type Capitulo, type ModuloManual, type PapelManual } from './conteudo';

interface VideoManual { capitulo: string; url: string; titulo: string | null; atualizado_em: string; atualizado_por: string | null }

/** Converte links comuns em endereço de player embutido. */
export function linkEmbutido(url: string): string | null {
  try {
    const u = new URL(url);
    const h = u.hostname.replace(/^www\./, '');
    if (h === 'youtu.be') return `https://www.youtube.com/embed/${u.pathname.slice(1)}`;
    if (h.endsWith('youtube.com')) {
      if (u.pathname.startsWith('/embed/')) return url;
      if (u.pathname.startsWith('/shorts/')) return `https://www.youtube.com/embed/${u.pathname.split('/')[2]}`;
      const v = u.searchParams.get('v');
      return v ? `https://www.youtube.com/embed/${v}` : null;
    }
    if (h === 'vimeo.com') { const id = u.pathname.split('/').filter(Boolean)[0]; return id && /^\d+$/.test(id) ? `https://player.vimeo.com/video/${id}` : null; }
    if (h === 'player.vimeo.com') return url;
    if (h.endsWith('loom.com')) { const id = u.pathname.split('/').filter(Boolean).pop(); return id ? `https://www.loom.com/embed/${id}` : null; }
    if (h === 'drive.google.com') { const m = u.pathname.match(/\/file\/d\/([^/]+)/); return m ? `https://drive.google.com/file/d/${m[1]}/preview` : null; }
    return null;
  } catch { return null; }
}

const ORDEM_PAPEIS: PapelManual[] = ['admin', 'vendas', 'imobiliaria', 'corretor'];

export function Manual({ papel, modulosDe }: { papel: PapelManual; modulosDe: (p: PapelManual) => Set<ModuloManual> }) {
  const { avisar } = useDialogos();
  const admin = papel === 'admin';
  const [comoPapel, setComoPapel] = useState<PapelManual>(papel);
  const [busca, setBusca] = useState('');
  const [aberto, setAberto] = useState<string>(() => (typeof location !== 'undefined' && location.hash.slice(1)) || 'primeiros-passos');
  const [videos, setVideos] = useState<Record<string, VideoManual>>({});
  const [editandoVideo, setEditandoVideo] = useState<{ url: string; titulo: string } | null>(null);

  const carregarVideos = useCallback(async () => {
    const { data } = await supabase.from('manual_videos').select('*');
    setVideos(Object.fromEntries(((data as VideoManual[]) ?? []).map((v) => [v.capitulo, v])));
  }, []);
  useEffect(() => { carregarVideos(); }, [carregarVideos]);

  const visiveis = useMemo(() => modulosDe(comoPapel), [modulosDe, comoPapel]);
  const capitulos = useMemo(() => CAPITULOS.filter((c) => c.papeis.includes(comoPapel) && (c.modulo === 'geral' || visiveis.has(c.modulo))), [comoPapel, visiveis]);
  const blocosDe = (c: Capitulo) => c.blocos.filter((b) => !b.papeis || b.papeis.includes(comoPapel));
  const novidades = NOVIDADES.filter((n) => !n.papeis || n.papeis.includes(comoPapel));

  // busca no texto de cada capítulo (título, resumo e blocos visíveis)
  const termo = busca.trim().toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  const casa = (c: Capitulo) => {
    if (!termo) return true;
    const txt = [c.titulo, c.resumo, ...(c.responsabilidades?.[comoPapel] ?? []),
      ...blocosDe(c).flatMap((b) => [b.titulo, b.texto ?? '', b.dica ?? '', b.atencao ?? '', ...(b.passos ?? []), ...(b.itens ?? [])])]
      .join(' ').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
    return txt.includes(termo);
  };
  const lista = capitulos.filter(casa);
  const atual = aberto === 'novidades' ? null : capitulos.find((c) => c.id === aberto) ?? capitulos[0];

  useEffect(() => { setEditandoVideo(null); }, [aberto]);
  const abrir = (id: string) => {
    setAberto(id);
    try { history.replaceState(null, '', `#${id}`); } catch { /* */ }
    document.querySelector('.manual-conteudo')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const salvarVideo = async (capitulo: string, url: string, titulo: string) => {
    if (url.trim() && !/^https:\/\//.test(url.trim())) { avisar('O link precisa começar com https://', 'erro'); return; }
    const { error } = await supabase.rpc('salvar_video_manual', { p_capitulo: capitulo, p_url: url.trim() || null, p_titulo: titulo || null });
    if (error) { avisar('Não foi possível salvar o vídeo.', 'erro'); return; }
    avisar(url.trim() ? 'Vídeo salvo neste capítulo.' : 'Vídeo removido.');
    setEditandoVideo(null); carregarVideos();
  };

  return (
    <section className="secao manual">
      <div className="secao-topo">
        <div>
          <h2>Manual do sistema</h2>
          <p className="sub">O que você pode fazer em cada módulo, passo a passo. Revisado em {REVISAO_MANUAL}.</p>
        </div>
        <div className="botoes">
          {admin && (
            <label className="manual-como">Ver como
              <select value={comoPapel} onChange={(e) => setComoPapel(e.target.value as PapelManual)}>
                {ORDEM_PAPEIS.map((p) => <option key={p} value={p}>{ROTULO_PAPEL[p]}</option>)}
              </select>
            </label>
          )}
          <button className="botao" onClick={() => window.print()}><Printer size={16} /> Imprimir ou salvar em PDF</button>
        </div>
      </div>

      <div className="manual-grade">
        <nav className="manual-indice" aria-label="Capítulos do manual">
          <label className="manual-busca"><Search size={15} /><input type="search" placeholder="Buscar no manual" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
          <button className={`manual-item novidades ${aberto === 'novidades' ? 'ativo' : ''}`} onClick={() => abrir('novidades')}><Sparkles size={15} /> Novidades</button>
          {lista.map((c) => (
            <button key={c.id} className={`manual-item ${atual?.id === c.id && aberto !== 'novidades' ? 'ativo' : ''}`} onClick={() => abrir(c.id)}>
              {c.titulo}{videos[c.id] && <Video size={13} className="manual-tem-video" aria-label="tem vídeo" />}
            </button>
          ))}
          {!lista.length && <p className="sub">Nada encontrado para “{busca}”.</p>}
        </nav>

        <article className="manual-conteudo">
          {aberto === 'novidades' || !atual ? (
            <>
              <h3>Novidades</h3>
              <p className="sub">O que mudou no sistema, das mais recentes para as mais antigas.</p>
              {novidades.map((n) => (
                <div key={n.data + n.titulo} className="manual-novidade">
                  <span className="sub">{n.data}</span>
                  <strong>{n.titulo}</strong>
                  <ul>{n.itens.map((i) => <li key={i}>{i}</li>)}</ul>
                </div>
              ))}
            </>
          ) : (
            <>
              <h3>{atual.titulo}</h3>
              <p className="manual-resumo">{atual.resumo}</p>

              {/* vídeo explicativo */}
              {videos[atual.id] ? (
                <div className="manual-video">
                  {linkEmbutido(videos[atual.id].url) ? (
                    <div className="manual-player"><iframe src={linkEmbutido(videos[atual.id].url)!} title={videos[atual.id].titulo || `Vídeo: ${atual.titulo}`} allow="autoplay; fullscreen; picture-in-picture" allowFullScreen loading="lazy" /></div>
                  ) : (
                    <a className="botao" href={videos[atual.id].url} target="_blank" rel="noreferrer"><Video size={16} /> Assistir ao vídeo: {videos[atual.id].titulo || atual.titulo}</a>
                  )}
                  {videos[atual.id].titulo && <p className="sub">{videos[atual.id].titulo}</p>}
                </div>
              ) : admin ? (
                <div className="manual-video vazio-video"><Video size={18} /> <span>Espaço para o vídeo explicativo deste capítulo.</span></div>
              ) : null}
              {admin && (
                editandoVideo ? (
                  <div className="manual-video-form">
                    <input placeholder="Link do vídeo (YouTube, Vimeo, Loom ou Google Drive)" value={editandoVideo.url} onChange={(e) => setEditandoVideo({ ...editandoVideo, url: e.target.value })} />
                    <input placeholder="Título (opcional)" value={editandoVideo.titulo} onChange={(e) => setEditandoVideo({ ...editandoVideo, titulo: e.target.value })} />
                    <button className="botao principal" onClick={() => salvarVideo(atual.id, editandoVideo.url, editandoVideo.titulo)}>Salvar vídeo</button>
                    {videos[atual.id] && <button className="botao" onClick={() => salvarVideo(atual.id, '', '')}>Remover vídeo</button>}
                    <button className="botao" onClick={() => setEditandoVideo(null)}>Cancelar</button>
                  </div>
                ) : (
                  <p className="manual-video-acao"><button className="link" onClick={() => setEditandoVideo({ url: videos[atual.id]?.url ?? '', titulo: videos[atual.id]?.titulo ?? '' })}>
                    {videos[atual.id] ? 'Trocar o vídeo deste capítulo' : 'Adicionar vídeo a este capítulo'}</button>
                    {videos[atual.id] && <span className="sub"> · por {videos[atual.id].atualizado_por} em {formatarDataHora(videos[atual.id].atualizado_em)}</span>}
                  </p>
                )
              )}

              {atual.responsabilidades?.[comoPapel] && (
                <div className="manual-papel">
                  <strong>O que se espera de você ({ROTULO_PAPEL[comoPapel]})</strong>
                  <ul>{atual.responsabilidades[comoPapel]!.map((r) => <li key={r}>{r}</li>)}</ul>
                </div>
              )}

              {blocosDe(atual).map((b) => (
                <Fragment key={b.titulo}>
                  <h4>{b.titulo}</h4>
                  {b.texto && <p>{b.texto}</p>}
                  {b.passos && <ol>{b.passos.map((p) => <li key={p}>{p}</li>)}</ol>}
                  {b.itens && <ul>{b.itens.map((p) => <li key={p}>{p}</li>)}</ul>}
                  {b.atencao && <p className="manual-atencao"><strong>Atenção:</strong> {b.atencao}</p>}
                  {b.dica && <p className="manual-dica"><strong>Dica:</strong> {b.dica}</p>}
                </Fragment>
              ))}
            </>
          )}
        </article>
      </div>

      {/* versão para impressão: todos os capítulos do perfil */}
      <div className="manual-impressao">
        <h2>Manual do sistema · {ROTULO_PAPEL[comoPapel]}</h2>
        <p>Revisado em {REVISAO_MANUAL}.</p>
        {capitulos.map((c) => (
          <section key={c.id}>
            <h3>{c.titulo}</h3>
            <p>{c.resumo}</p>
            {c.responsabilidades?.[comoPapel] && <><strong>O que se espera de você</strong><ul>{c.responsabilidades[comoPapel]!.map((r) => <li key={r}>{r}</li>)}</ul></>}
            {blocosDe(c).map((b) => (
              <Fragment key={b.titulo}>
                <h4>{b.titulo}</h4>
                {b.texto && <p>{b.texto}</p>}
                {b.passos && <ol>{b.passos.map((p) => <li key={p}>{p}</li>)}</ol>}
                {b.itens && <ul>{b.itens.map((p) => <li key={p}>{p}</li>)}</ul>}
                {b.atencao && <p><strong>Atenção:</strong> {b.atencao}</p>}
                {b.dica && <p><strong>Dica:</strong> {b.dica}</p>}
              </Fragment>
            ))}
          </section>
        ))}
      </div>
    </section>
  );
}
