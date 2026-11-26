# Colocar o servidor na hospedagem (passo a passo)

O servidor PHP fica numa subpasta do domínio que você já tem: `https://presenca.example.com/presenca/`.
Não precisa mexer em DNS nem criar domínio novo.

## Parte 1 — Gerar o pacote (no seu PC)

1. Dê duplo clique em **`4 - Gerar Pacote do Servidor (hospedagem).bat`**.
2. Quando perguntar o endereço, digite: `https://presenca.example.com/presenca`
3. Ele cria `Entregas\Servidor\presenca.zip` e mostra o **usuário e a senha** do painel.
   - Token e senha ficam em `Servidor\credenciais.json`. **Não compartilhe esse arquivo.**

## Parte 2 — Subir na hospedagem

1. No painel da hospedagem, abra **Gerenciador de arquivos**.
2. Entre na pasta do domínio `presenca.example.com` → `public_html`.
3. Crie uma pasta chamada **`presenca`** e entre nela.
4. **Envie** o `presenca.zip` e **extraia** (botão direito → Extrair).
5. Confira que apareceram, dentro de `presenca`: `index.php`, `.htaccess` e a pasta `_app`.
   - O `.htaccess` começa com ponto e pode estar escondido. No Gerenciador de arquivos, ative
     "mostrar arquivos ocultos" (geralmente na engrenagem/configurações da tela).
6. Pode apagar o `presenca.zip` da hospedagem depois de extrair.

## Parte 3 — Conferir o PHP

1. No painel: **Configurar PHP** (menu "Recursos extras").
2. Escolha **PHP 8.1 ou mais novo** (7.4 também funciona).
3. Confirme que as extensões **`pdo_sqlite`** e **`sqlite3`** estão marcadas/ativas.
   - Se não aparecerem na lista, veja o item "SQLite indisponível" na tabela de problemas abaixo.

## Parte 4 — Testar

Abra no navegador: **`https://presenca.example.com/presenca/health`**

Deve aparecer algo assim:

```json
{"ok":true,"versao":"2.0","sqlite":true,"configurado":true,"auth_header":false}
```

- `sqlite: true` e `configurado: true` = tudo certo.
- Depois abra **`https://presenca.example.com/presenca/`**, entre com o usuário e a senha (tela de login) e veja o painel.

## Parte 5 — Instalar os agentes

1. No seu PC, dê duplo clique em **`3 - Gerar Pacote do Agente.bat`**.
2. No endereço, digite: `https://presenca.example.com/presenca`
   (ele detecta sozinho que é a hospedagem e usa o token certo).
3. Leve o `Entregas\Agente\Pacote-Agente.zip` aos PCs e dê dois cliques em `INSTALAR.bat`.
4. **PCs que você já instalou nos testes** (apontando para o seu PC) precisam ser reinstalados com este pacote novo.
5. Para ver o resultado sem esperar 15 minutos, em um PC com o agent:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\PresencaAgente\Detectar-Presenca.ps1" -IgnorarHorario
```

Deve aparecer `Servidor: enviado`. Atualize o painel.

## Atualizar o servidor depois (sem perder nada)

Quando eu mudar o servidor ou o painel, rode o atalho **`4 - Gerar Pacote do Servidor (hospedagem).bat`** de novo (endereço `https://presenca.example.com/presenca`) e envie o **`Entregas\Servidor\presenca-atualizacao.zip`** para a pasta `presenca` da hospedagem, extraindo **por cima** (substituir).

- O `presenca-atualizacao.zip` **não leva o `config.php`**: sua senha, token e ajustes ficam como estão.
- Os dados (`_app/dados/presenca.sqlite`) nunca vão em zip nenhum: o histórico é preservado.
- O `presenca.zip` (completo) é só para a primeira instalação.

## Situações que o painel mostra

| Situação | Significa |
|---|---|
| **Presencial** | Na rede física de uma unidade (MTZ, FL1, FL2), sem VPN |
| **Presencial via VPN** | Na rede física de uma unidade, com a VPN ligada |
| **Remoto via VPN** | Fora das unidades, com a VPN ligada |
| **Remoto** | Fora das unidades, sem VPN |
| **Sem rede** | Nenhuma rede física com gateway |
| **Sem sinal** | O PC não envia dados há mais que `online_min` minutos |

## Detecção rápida de troca de rede

O agent roda a cada 5 minutos **e imediatamente** quando o PC conecta/desconecta de uma rede, faz logon ou desbloqueia a tela. Depois de trocar de rede, o painel atualiza em cerca de 30 segundos (20 s de espera do agent + até 30 s do painel).

Para o painel marcar "Sem sinal" mais cedo, na hospedagem edite `presenca/_app/config.php` e troque `'online_min' => 45` por `'online_min' => 20`.

## Se algo der errado

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `/health` dá erro 404 | `.htaccess` não foi extraído ou o `mod_rewrite` está desligado | Confira se o `.htaccess` está em `presenca/`. Se estiver, peça ao suporte para confirmar o `mod_rewrite`. |
| `/health` mostra `"sqlite":false` | Extensão SQLite desligada | Ative `pdo_sqlite` em Configurar PHP. Se não existir, me avise: eu adapto o servidor para o MySQL (phpMyAdmin que você já tem). |
| `/health` mostra `"configurado":false` | `_app/config.php` não está lá | Extraia o zip de novo mantendo as pastas. |
| Erro 500 | Versão do PHP antiga ou permissão | Use PHP 7.4+; a pasta `presenca` precisa permitir escrita (755) para criar `_app/dados`. |
| Login não aceita a senha | Senha digitada errada (5 erros bloqueiam por 15 min) ou a senha já foi trocada pelo painel | Use a de `credenciais.json` só se nunca a trocou. Se esqueceu, outro administrador redefine em Administração → Usuários. Se era o único: no Gerenciador de arquivos, edite `_app/config.php` e acrescente `'redefinir_senha_admin' => 'UmaSenhaNova123',` (mín. 8 caracteres); entre com ela, troque pelo painel e **apague essa linha**. |
| Agent diz `na_fila` ou não aparece no painel | O PC não alcança o endereço, ou o token é de outro servidor | Abra o endereço no navegador desse PC. Refaça o pacote do agente com o endereço da hospedagem. |
| Erro 403 no envio do agent | O firewall da hospedagem (WAF) bloqueou o envio | No painel: **Web Application Firewall** — libere a pasta `presenca` ou me mande o erro. |

## Segurança (importante)

- Os dados ficam em `presenca/_app/dados/presenca.sqlite`. A pasta `_app` é bloqueada ao navegador (regras do `.htaccess` + o `index.php` responde 404 a qualquer outro caminho). Teste: abrir `https://presenca.example.com/presenca/_app/config.php` deve dar **404**.
- Faça backup do arquivo `presenca.sqlite` de vez em quando (Gerenciador de arquivos → baixar).
- Guarde `Servidor\credenciais.json` num lugar seguro. Se vazar, apague-o, gere de novo (apague antes o arquivo para trocar token e senha) e reinstale os agentes.
- Senha do painel: troque pelo próprio painel (botão **Trocar senha**). A senha do `config.php` (`painel_pass`) só vale para criar o primeiro administrador; depois que ele existe, mudá-la no arquivo não tem efeito.

## Novidades da versão 2 (login, sites acessados, BI, localização)

1. Gere o pacote de atualização (`4 - Gerar Pacote do Servidor (hospedagem).bat`) e extraia **`presenca-atualizacao.zip` por cima** da pasta `presenca`. O banco antigo é migrado sozinho (as leituras de presença antigas entram no resumo por dia).
2. Abra `https://presenca.example.com/presenca/`: agora aparece a **tela de login**. Entre com o usuário/senha de sempre (`credenciais.json`); essa conta vira o **administrador**.
3. Reinstale os agentes com o pacote novo (`3 - Gerar Pacote do Agente.bat`): só o agent novo envia **nome completo** e **sites acessados**. Os antigos continuam funcionando (só presença).
4. Em **Administração**, preencha setor/nome de quem faltar e crie usuários **Gestor** (só consulta) para quem for ver os relatórios.
5. Em **Classificação de sites**, classifique os sites mais acessados que ainda estão sem regra.
6. Se a empresa tiver feriados (afetam os dias úteis da localização), liste-os em `_app/config.php`: `'feriados' => ['2026-04-21', '2026-05-01'],`.

Antes de ligar a coleta de sites, leia "Uso responsável (LGPD)" no `README.md`.



## Proteções de segurança (2FA, limite de tentativas, auditoria)

Ao atualizar o servidor, o banco ganha as tabelas novas sozinho. O `config.php` existente continua valendo e **não** recebe as opções novas (todas têm padrão seguro). Para usá-las, edite `presenca/_app/config.php` no Gerenciador de arquivos e acrescente as linhas antes de `];`:

```php
'exigir_2fa' => true,        // depois que todos ativarem o 2FA
'login_max_falhas_ip' => 20, // falhas por IP em 15 min antes de bloquear o IP
```

Passo a passo: entre, clique em **Ativar verificação em 2 etapas**, guarde os códigos de recuperação e, quando todos tiverem ativado, ligue `exigir_2fa`. Em **Administração → Auditoria** você vê quem entrou, de qual IP e o que foi exportado ou alterado.