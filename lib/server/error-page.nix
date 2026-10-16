# Pas d'apostrophe droite dans le texte (la page vit entre apostrophes dans nginx) : `&rsquo;`.
{
  title,
  body,
  withLinks ? false,
}:
''
  <!doctype html>
  <html lang="fr"><head><meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title}</title>
  <style>
  :root{color-scheme:light dark}
  body{margin:0;min-height:100vh;display:grid;place-items:center;padding:2rem;
    font:16px/1.6 system-ui,-apple-system,sans-serif;background:#fafafa;color:#1a1a1a}
  main{max-width:30rem;text-align:center}
  h1{font-size:1.4rem;margin:0 0 1rem;font-weight:600}
  p{margin:0 0 .75rem;color:#5a5a5a}
  ${if withLinks then "a{color:#3f7078}\n" else ""}@media(prefers-color-scheme:dark){
    body{background:#171717;color:#ededed}p{color:#a3a3a3}${
      if withLinks then "a{color:#7fb3bb}" else ""
    }}
  </style></head><body><main>
  <h1>${title}</h1>
  ${body}
  </main></body></html>''
