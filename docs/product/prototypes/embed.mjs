import { mkdirSync, readFileSync, writeFileSync } from "node:fs";

const css = readFileSync("compiled.css", "utf8");
const js = readFileSync("compiled.js", "utf8");
if (/<\/style/i.test(css) || /<\/script/i.test(js)) {
  throw new Error("Unsafe closing tag in compiled output");
}

mkdirSync("dist", { recursive: true });
writeFileSync(
  "dist/index.html",
  `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Hagig · private alpha prototype</title>
  <link rel="icon" href="data:,">
  <style>${css}</style>
</head>
<body>
  <div id="root"></div>
  <script>${js}</script>
</body>
</html>`,
);
