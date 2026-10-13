# Segurança do Acerto: situação dos 19 pontos

Legenda: ✅ feito no código · 🔧 pronto, falta ligar o Supabase · ⚙️ configurar no painel · ➖ não se aplica hoje

> **Limite importante:** enquanto os dados ficam no navegador (`localStorage`), login e bloqueios rodam no próprio
> aparelho. Quem abre o DevTools consegue alterá-los. Segurança de verdade exige o backend (Supabase): é o que
> `supabase/schema.sql` prepara. Não use dados reais de clientes antes disso.

| # | Ponto | Estado | Onde / como |
|---|---|---|---|
| 1 | Variáveis de ambiente | ✅ | Nenhum segredo no código. `.gitignore` bloqueia `.env`; `.env.example` mostra o modelo. A chave `service_role` nunca vai ao site. |
| 2 | Validação no front | ✅ | Cadastro, login, cliente/fiado e pagamento: tipo, tamanho (`maxLength`), formato, CPF real, datas e valores. |
| 3 | Sanitização no servidor | 🔧 | `schema.sql`: gatilhos `sanitize_*` + `CHECK` em todas as colunas. |
| 4 | SQL Injection | ✅/🔧 | O front não monta SQL. No Supabase use sempre `.from('tabela').insert({...})` (parametrizado). |
| 5 | Autenticação | ✅ | Senha ≥ 8 com letras e números, sem senhas comuns. Sessão expira em 8 h e após 30 min parado. Sair limpa tudo. |
| 6 | IDOR / RLS | ✅/🔧 | Local: cada conta tem os próprios dados. Servidor: RLS `owner_id = auth.uid()` + chave composta que impede apontar para dado de outra conta. |
| 7 | Hash de senha | ✅ | PBKDF2-SHA256, 210.000 iterações, sal aleatório. No Supabase a senha é guardada com bcrypt. |
| 8 | Força bruta | ✅/⚙️ | 5 erros bloqueiam o login por 30 s (dobra até 15 min). Barreira só local; no Supabase ative os limites do Auth e CAPTCHA (Cloudflare Turnstile). |
| 9 | Duplicidade | ✅ | Botões desabilitados com "Entrando…/Criando conta…"; travas no salvar e no receber. |
| 10 | CSRF | ✅ | Sem cookies de sessão; `form-action 'none'`. Com Supabase o token vai no cabeçalho, que o navegador não envia sozinho. |
| 11 | Upload | ➖ | Não há upload. Se criar: limitar MIME, extensão e tamanho no bucket do Supabase. |
| 12 | Erros | ✅ | Mensagens genéricas; erros inesperados viram um aviso simples, sem detalhes técnicos. Logs técnicos: Supabase Logs ou Sentry. |
| 13 | Dependências | ✅ | Zero pacotes npm. Só Google Fonts (liberado na CSP). Se adicionar pacotes: `npm audit` e Dependabot. |
| 14 | Tokens | ⚙️ | Sessão local expira sozinha. No Supabase: JWT de 3600 s e rotação de refresh token. CSP + escape de HTML protegem o armazenamento. |
| 15 | Rate limiting | 🔧/⚙️ | `limit_inserts` (60 por minuto por conta). Auth: limites do Supabase. |
| 16 | LGPD | ✅ | Telefone mascarado nas tabelas. CPF, nome da mãe, endereço e nascimento do cadastro são validados mas **não gravados**. CPF do cliente é opcional. |
| 17 | SSRF | ➖ | Nenhum código de servidor busca URL informada pelo usuário. Links `wa.me` usam só dígitos. |
| 18 | Cookies | ➖ | Não usa cookies. Se usar: `HttpOnly; Secure; SameSite=Lax`. |
| 19 | CORS | ⚙️ | Supabase → Auth → URL Configuration: só o domínio oficial. A CSP (`connect-src`) limita para onde o site fala. |

## Cabeçalhos HTTP (`vercel.json`)
HSTS, `nosniff`, `X-Frame-Options: DENY`, `frame-ancestors 'none'`, Referrer-Policy, Permissions-Policy e CSP.
A CSP usa `'unsafe-inline'` em scripts porque o código está dentro do `index.html`. Para endurecer mais,
separe o JavaScript em arquivo próprio e remova o `'unsafe-inline'`.

## Ao ligar o Supabase
1. Rode `supabase/schema.sql` no SQL Editor.
2. Acrescente `https://SEU-PROJETO.supabase.co` em `connect-src` (no `index.html` e no `vercel.json`).
3. Auth → senha mínima de 8, confirmação de e-mail ligada, CAPTCHA ligado.
4. Teste o RLS com duas contas: uma não pode ver nada da outra.
