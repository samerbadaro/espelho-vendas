import { createRoot } from 'react-dom/client';
import { Publico } from './Publico';
import { TV } from './TV';
import { Painel } from './Painel';
import './estilo.css';

// Rotas: "/" link público · "/tv" salão de vendas · "/painel" Sec. Vendas
const rota = window.location.pathname.replace(/\/+$/, '') || '/';
const Pagina = rota === '/tv' ? TV : rota === '/painel' ? Painel : Publico;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : rota === '/painel' ? 'painel' : 'publico';

createRoot(document.getElementById('root')!).render(<Pagina />);
