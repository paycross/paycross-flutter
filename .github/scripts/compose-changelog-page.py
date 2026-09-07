"""Turn an SDK CHANGELOG.md into a developer-portal page.

The portal builds Markdown as MDX and resolves every link at build time, so two
things in an ordinary changelog fail the build: <https://…> autolinks, which MDX
reads as a JSX tag, and repo-relative links, which have no meaning once the file
is served from the portal. Both are rewritten here.

A leading `# Changelog` is dropped as well. The front matter already gives the
page its title, and Docusaurus prefers a body H1 over it, so leaving the file's
own title in would head the Android and iOS pages "Changelog" and lose the
platform the reader is looking at.
"""

import re
import sys

title, description, repo, source, dest = sys.argv[1:6]

AUTOLINK = re.compile(r'<((?:https?|mailto):[^\s<>`]+)>')
LINK = re.compile(r'(\]\()(?!(?:https?:|mailto:|#|/))([^)\s]+)(\))')
BLOB = f'https://github.com/paycross/{repo}/blob/main/'


def rewrite(line):
    parts = line.split('`')
    for i in range(0, len(parts), 2):
        parts[i] = AUTOLINK.sub(r'[\1](\1)', parts[i])
        parts[i] = LINK.sub(lambda m: m.group(1) + BLOB + m.group(2) + m.group(3), parts[i])
    return '`'.join(parts)


lines, fenced = [], False
for line in open(source, encoding='utf-8').read().split('\n'):
    if line.lstrip().startswith('```'):
        fenced = not fenced
    elif not fenced:
        line = rewrite(line)
    lines.append(line)

while lines and not lines[0].strip():
    lines.pop(0)
if lines and lines[0].startswith('# '):
    lines.pop(0)
    while lines and not lines[0].strip():
        lines.pop(0)

header = f'---\ntitle: {title}\ndescription: {description}\n---\n\n'
open(dest, 'w', encoding='utf-8').write(header + '\n'.join(lines))
