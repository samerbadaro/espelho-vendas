import { createRoot } from 'react-dom/client';
import { TV } from './TV';
import { Painel } from './Painel';
import { ProvedorMarca, ProvedorDialogos } from './ui';
import { CadastroImobiliaria } from './Cadastro';
import './estilo.css';

// Rotas: "/tv" salão de vendas, "/cadastro" pedido de acesso, "/painel" equipe, imobiliárias e corretores.
// O antigo link público ("/") foi desativado: qualquer outro endereço leva ao painel.
const rota = window.location.pathname.replace(/\/+$/, '') || '/';
const painel = rota === '/painel' || rota.startsWith('/painel/');
if (rota !== '/tv' && rota !== '/cadastro' && !painel) window.location.replace('/painel' + window.location.hash);
const Pagina = rota === '/tv' ? TV : rota === '/cadastro' ? CadastroImobiliaria : Painel;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : 'painel';

createRoot(document.getElementById('root')!).render(
  <ProvedorMarca>
    <ProvedorDialogos>
      <Pagina />
    </ProvedorDialogos>
  </ProvedorMarca>,
);
