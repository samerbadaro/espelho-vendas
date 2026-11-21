import { createRoot } from 'react-dom/client';
import { TV } from './TV';
import { Painel } from './Painel';
import { MeetingPublico } from './Meeting';
import { ProvedorMarca, ProvedorDialogos } from './ui';
import { CadastroImobiliaria } from './Cadastro';
import './estilo.css';
import { baseAba, semBase } from './rotaEmp';

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

// Rotas: "/tv" salão de vendas, "/cadastro" pedido de acesso, "/meeting/<endereço>" inscrição no meeting,
// "/painel" equipe, imobiliárias e corretores; "/e/<empreendimento>/painel/...": painel já dentro de um empreendimento.
// O antigo link público ("/") foi desativado: qualquer outro endereço leva ao painel.
if (baseAba && semBase(window.location.pathname).replace(/\/+$/, '') === '') window.location.replace(`${baseAba}/painel`);
const rota = semBase(window.location.pathname).replace(/\/+$/, '') || '/';
const painel = rota === '/painel' || rota.startsWith('/painel/');
const slugMeeting = rota.match(/^\/meeting\/([a-z0-9-]+)$/)?.[1];
if (rota !== '/tv' && rota !== '/cadastro' && !painel && !slugMeeting) window.location.replace('/painel' + window.location.hash);
const Pagina = rota === '/tv' ? TV : rota === '/cadastro' ? CadastroImobiliaria : slugMeeting ? () => <MeetingPublico slug={slugMeeting} /> : Painel;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : slugMeeting ? 'meeting' : 'painel';

// Faixa de aviso quando não é a produção (ex.: v2 em testes)
const ambiente = import.meta.env.VITE_AMBIENTE as string | undefined;
if (ambiente) {
  const faixa = document.createElement('div');
  faixa.className = 'faixa-ambiente';
  faixa.textContent = ambiente;
  document.body.prepend(faixa);
}

createRoot(document.getElementById('root')!).render(
  <ProvedorMarca>
    <ProvedorDialogos>
      <Pagina />
    </ProvedorDialogos>
  </ProvedorMarca>,
);
