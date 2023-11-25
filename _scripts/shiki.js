import { runTwoSlash, renderCodeToHTML, createShikiHighlighter } from 'shiki-twoslash'
import { stdin } from 'process'
import { createInterface } from 'readline'

(async () => {
  const highlighter = await createShikiHighlighter({ theme: 'material-default' });
  const lines = createInterface({ input: stdin, terminal: false });
  for await (const line of lines) {
    const sep = line.indexOf(';');
    const lang = line.substring(0, sep);
    const code = line.substring(sep + 1).replace(/\\n/g, '\n');
    const twoslash = runTwoSlash(code, lang, {});
    const output = renderCodeToHTML(twoslash.code, lang, { twoslash: true }, {
      defaultCompilerOptions: { strict: true },
      themeName: 'monokai',
      wrapFragments: true,
    }, highlighter, twoslash);
    console.log(output.replace(/\n/g, '\\n'));
  }
})()
