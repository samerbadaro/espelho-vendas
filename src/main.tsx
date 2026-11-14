import { createRoot } from 'react-dom/client';
import { Publico } from './Publico';
import { TV } from './TV';
import { Painel } from './Painel';
import { ProvedorMarca, ProvedorDialogos } from './ui';
import { CadastroImobiliaria } from './Cadastro';
import './estilo.css';

// Rotas: "/" link público, "/tv" salão de vendas, "/painel" equipe, imobiliárias e corretores
const rota = window.location.pathname.replace(/\/+$/, '') || '/';
const painel = rota === '/painel' || rota.startsWith('/painel/');
const Pagina = rota === '/tv' ? TV : rota === '/cadastro' ? CadastroImobiliaria : painel ? Painel : Publico;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : painel || rota === '/cadastro' ? 'painel' : 'publico';

createRoot(document.getElementById('root')!).render(
  <ProvedorMarca>
    <ProvedorDialogos>
      <Pagina />
    </ProvedorDialogos>
  </ProvedorMarca>,
);
