-- Portal do Corretor
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare i portal_itens; begin
  i := adicionar_item_portal('tour_virtual', 'Tour 360º do decorado', null, 'https://exemplo.com/tour');
  raise notice '%  Sec. Vendas adiciona link', case when i.link is not null then 'OK    ' else 'FALHOU' end;
  i := adicionar_item_portal('book', 'Book Duo Haus', 'Versão de lançamento', null, 'book/abc.pdf', 'book.pdf', 1000, 'application/pdf');
  raise notice '%  Sec. Vendas adiciona arquivo', case when i.caminho='book/abc.pdf' then 'OK    ' else 'FALHOU' end;
  begin perform adicionar_item_portal('videos', 'Sem nada'); raise notice 'FALHOU  sem arquivo nem link';
  exception when others then raise notice '%  Exige arquivo ou link (%)', case when sqlerrm='ARQUIVO_OU_LINK' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform adicionar_item_portal('videos', 'Link ruim', null, 'javascript:alert(1)'); raise notice 'FALHOU  link inválido';
  exception when others then raise notice '%  Link precisa começar com http (%)', case when sqlerrm='LINK_INVALIDO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform adicionar_item_portal('outra', 'Item qualquer', null, 'https://a.com'); raise notice 'FALHOU  categoria';
  exception when others then raise notice '%  Categoria fora da lista é recusada (%)', case when sqlerrm='CATEGORIA_INVALIDA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  raise notice '%  Corretor vê os materiais', case when (select count(*) from portal_itens)=2 then 'OK    ' else 'FALHOU' end;
  begin perform adicionar_item_portal('book', 'Meu book', null, 'https://a.com'); raise notice 'FALHOU  corretor adiciona';
  exception when others then raise notice '%  Corretor não adiciona (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform remover_item_portal((select id from portal_itens limit 1)); raise notice 'FALHOU  corretor remove';
  exception when others then raise notice '%  Corretor não remove (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  raise notice '%  Imobiliária vê os materiais', case when (select count(*) from portal_itens)=2 then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare c text; begin
  c := remover_item_portal((select id from portal_itens where titulo='Book Duo Haus'));
  raise notice '%  Administrador remove e recebe o arquivo para apagar', case when c='book/abc.pdf' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false) \g /dev/null
do $$ begin
  raise notice '%  Visitante sem login não vê nada', case when (select count(*) from portal_itens)=0 then 'OK    ' else 'FALHOU' end;
exception when others then raise notice 'OK      Visitante sem login não vê nada (%)', sqlerrm; end $$;
reset role;
