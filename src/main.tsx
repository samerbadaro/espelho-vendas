import { createRoot } from 'react-dom/client';
import { TV } from './TV';
import { Painel } from './Painel';
import { ProvedorMarca, ProvedorDialogos } from './ui';
import { CadastroImobiliaria } from './Cadastro';
import './estilo.css';

// Depois de uma nova publicação, a aba aberta ainda aponta para arquivos antigos (que deixam de existir).
// Quando um desses arquivos falha ao carregar, recarrega a página uma vez para pegar a versão nova.
window.addEventListener('vite:preloadError', (e) => {
  const chave = 'recarregado-versao';
  if (sessionStorage.getItem(chave) === location.pathname) return;
  e.preventDefault();
  try { sessionStorage.setItem(chave, location.pathname); } catch { /* sem armazenamento */ }
  location.reload();
});
window.addEventListener('load', () => setTimeout(() => { try { sessionStorage.removeItem('recarregado-versao'); } catch { /* */ } }, 10000));

// Rotas: "/tv" salão de vendas, "/cadastro" pedido de acesso, "/painel" equipe, imobiliárias e corretores.
// O antigo link público ("/") foi desativado: qualquer outro endereço leva ao painel.
const rota = window.location.pathname.replace(/\/+$/, '') || '/';
const painel = rota === '/painel' || rota.startsWith('/painel/');
if (rota !== '/tv' && rota !== '/cadastro' && !painel) window.location.replace('/painel' + window.location.hash);
const Pagina = rota === '/tv' ? TV : rota === '/cadastro' ? CadastroImobiliaria : Painel;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : 'painel';

// Faixa de aviso quando não é a produção (homologação)
const ambiente = import.meta.env.VITE_AMBIENTE as string | undefined;
if (ambiente) {
  const faixa = document.createElement('div');
  faixa.className = 'faixa-ambiente';
  faixa.textContent = ambiente;
  document.body.prepend(faixa);
  document.title = `[HOMOLOGAÇÃO] ${document.title}`;
}

createRoot(document.getElementById('root')!).render(
  <ProvedorMarca>
    <ProvedorDialogos>
      <Pagina />
    </ProvedorDialogos>
  </ProvedorMarca>,
);
