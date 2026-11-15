// Empreendimento da aba: vem do endereço (/e/<endereço>/painel/...).
// O resto do sistema continua usando "/painel/..."; aqui o prefixo entra e sai.
const m = window.location.pathname.match(/^\/e\/([a-z0-9][a-z0-9-]{1,39})(\/.*)?$/);
export const slugAba: string | null = m?.[1] ?? null;
export const baseAba = slugAba ? `/e/${slugAba}` : '';
/** Caminho sem o prefixo do empreendimento. */
export const semBase = (p: string) => (baseAba && p.startsWith(baseAba) ? p.slice(baseAba.length) || '/' : p);
/** Caminho do painel com o prefixo do empreendimento da aba. */
export const comBase = (p: string) => (baseAba && p.startsWith('/painel') ? baseAba + p : p);
/** Entra num empreendimento (recarrega: marca, dados e tempo real passam a ser dele). */
export const entrarNoEmpreendimento = (slug: string, caminho = '/painel') => { window.location.href = `/e/${slug}${caminho}`; };
export const irParaVitrine = () => { window.location.href = '/painel'; };
