# Hand-off: Blog Site Template (Astro + Content Collections)

> Builds on `02-handoff-skeleton.md` (the generic site skeleton) and connects to `05`–`08` (the content sync pipeline). Layers blog-specific capability onto a skeleton-based Astro site: content collection config, the three templates that matter (post, index, RSS), and the build-time fetch that ties the site repo to the content repo.

## Status

Designed, not yet built. The shape was sketched in the chat that produced the VPS content sync docs; this doc formalizes it.

## What this covers

- The Obsidian-side author workflow (creating, drafting, publishing a post).
- Frontmatter conventions for posts.
- Astro Content Collections setup pointing at fetched content.
- Three templates: single post page, blog index, RSS feed.
- The `fetch-content.sh` glue that runs before `astro build`.
- Deliberate omissions and what to defer to "v2."

## What this assumes

- A skeleton-based site repo per `02-handoff-skeleton.md` (Astro 6, static output, plain CSS).
- A content sync pipeline running per `05`/`06`/`07`/`08`. Pattern matters slightly:
  - **Pattern A** (single shared content repo): site repo's `fetch-content.sh` does a sparse clone of `sites/SITE-NAME/`.
  - **Pattern B** (per-site content repo): site repo's `fetch-content.sh` does a full shallow clone; the whole repo *is* this site's content.
  This doc shows the Pattern B path because it's simpler; the Pattern A variant is one line different.
- A per-site content repo (or content-repo subdirectory) containing markdown files under `posts/`.

## The author workflow

The whole game is keeping "writing" and "publishing" indistinguishable from each other. There is no "publish event" — there's only "the file exists in the right state in the right place."

### Creating a post

In Obsidian, use a vault template (Templater plugin, the built-in Templates core plugin, or just a copy-able stub) that stamps in the frontmatter scaffold so you never type it from scratch:

```markdown
---
title: ""
date:
description: ""
tags: []
---


```

Bind it to a hotkey. New post = one keystroke + filename + write.

### Drafts and the publish gesture

The convention:

- **`vault/sites/SITE-NAME/drafts/`** — work-in-progress. Nothing here is on the live site. Half-thoughts live here forever if they want to.
- **`vault/sites/SITE-NAME/posts/`** — published. Anything that lands here will be on the next build.

The publish gesture is **moving the file from `drafts/` to `posts/`**. That's it. No frontmatter flag to flip, no command to run, no UI to open. Obsidian's file explorer makes the state legible at a glance: I can see what's in flight and what's live without leaving the editor.

**How the exclusion actually works.** The reconciler's rsync (`05`/`07`, baked into reconciler v1.1.1+ in `08`) has `--exclude='drafts'`, so anything in a directory named `drafts` stays on the VPS and never enters the content repo. The inotify watcher also ignores `drafts/` so editing a draft doesn't fire wasted reconciliation cycles. This is convention-driven: the exclusion matches any directory named `drafts` at any depth. If you rename your draft folder to something else, you'd need to update the reconciler's exclude pattern to match.

Reasoning: folder-as-publish beats `draft: true` in frontmatter because the folder is visible without opening the file, can't be silently mis-set, and the publish gesture is a single filesystem operation that the rsync pipeline can cleanly filter on.

### When to set the date

Stamp the date when you move the file to `posts/`, not when you create it. Otherwise drafts that ripen for weeks ship with stale creation dates pretending to be older than they are when they finally went out. The vault template above leaves `date:` blank intentionally — fill it at publish time.

### Multi-device considerations

The author workflow assumes a single vault on Obsidian Sync. The publish gesture (folder move) works identically on phone, tablet, and desktop. The VPS just sees the resulting file move and reconciles.

## Post anatomy

### Frontmatter

Keep it small. The temptation is to add fields you might use someday — don't.

```yaml
---
title: "The post title"
date: 2026-05-23
description: "One-sentence summary for the index and social meta."
tags: [optional, keywords]
---
```

That's the whole schema for v1. No `author` (it's always you). No `slug` (derive it from the filename). No `cover_image` until you've actually wanted one twice. No `updated` until you've genuinely updated a post. Adding a field is cheap; removing one is annoying.

`description` is optional but worth writing — it doubles as the index excerpt and the social-share meta tag, and "what's this post about in one sentence?" is a useful forcing function.

### Body

Plain markdown. Conventions:

- Headings start at `##` (H2). The post's H1 is rendered from the frontmatter `title` by the template, so don't write a `# Title` line in the body.
- Code fences with language hints work normally.
- Standard markdown links: `[text](url)`.
- Avoid Obsidian-specific syntax that doesn't render in vanilla markdown:
  - **Wikilinks** (`[[file]]`) — won't resolve. Use standard markdown links.
  - **Embeds** (`![[file]]`) — won't resolve. Use standard markdown image syntax.
  - **Callouts** (`> [!note]`) — render as plain blockquotes; the `[!note]` prefix shows up as literal text.

In Obsidian settings, set **Files & Links → Use [[Wikilinks]] → Off** for the vault (or at least for the synced site folders). The "New link format" should be "Relative path to file" or "Absolute path" — whichever you prefer, but consistent.

### Embedded media

Working baseline: store images under `sites/SITE-NAME/posts/attachments/` in the vault. Reference them in markdown with relative paths:

```markdown
![Alt text](./attachments/image.jpg)
```

The reconciler rsyncs `attachments/` along with the markdown (it's all under `posts/`), so they arrive at the content repo intact. Astro's image handling at build time resolves the relative paths.

Configure Obsidian: **Files & Links → Default location for new attachments → "In subfolder under current folder"**, with the subfolder name set to `attachments`. This makes paste-an-image-from-clipboard work without thinking.

**Open question:** whether to lean on Astro's image optimization (`<Image />` component) or just pass through `<img>` tags from the markdown. Image optimization is real value (responsive sizes, format conversion, lazy loading) but requires using MDX or a remark plugin to rewrite `<img>` to `<Image />`. For v1, plain `<img>` is fine; revisit if the site picks up enough image-heavy posts.

## Content Collections setup

Astro 5+ uses the Content Layer API. Collections are defined with a loader and a Zod schema; pages query them via `getCollection()`.

### File layout in the site repo

```
src/
├── content.config.ts          # collection definitions
├── layouts/
│   ├── BaseLayout.astro       # from skeleton
│   └── PostLayout.astro       # new
├── pages/
│   ├── index.astro            # blog index (if blog is at /)
│   ├── posts/
│   │   └── [...slug].astro    # single post page
│   └── rss.xml.js             # RSS feed
└── scripts/
    └── fetch-content.sh       # runs before astro build

content/                       # gitignored; populated at build time
└── posts/
    ├── attachments/
    └── *.md
```

`.gitignore` should include `content/` — it's a build artifact, not source.

### `src/content.config.ts`

```ts
import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const posts = defineCollection({
  loader: glob({
    pattern: '**/*.md',
    base: './content/posts',
  }),
  schema: z.object({
    title: z.string(),
    date: z.coerce.date(),
    description: z.string().optional(),
    tags: z.array(z.string()).optional(),
  }),
});

export const collections = { posts };
```

`z.coerce.date()` accepts the `YYYY-MM-DD` strings out of Obsidian's frontmatter and converts them to Date objects. Without `coerce`, you'd have to write `date: !!timestamp 2026-05-23` in the YAML, which nobody wants to remember.

The `glob` loader picks up any `.md` files under `content/posts/`, including in subdirectories. If you ever want to organize posts in year folders (`content/posts/2026/the-post.md`), no schema change is needed — the slug just gains a year prefix.

## The three templates

### Single post page — `src/pages/posts/[...slug].astro`

```astro
---
import { getCollection, render } from 'astro:content';
import BaseLayout from '../../layouts/BaseLayout.astro';

export async function getStaticPaths() {
  const posts = await getCollection('posts');
  return posts.map(post => ({
    params: { slug: post.id },
    props: { post },
  }));
}

const { post } = Astro.props;
const { Content } = await render(post);
---

<BaseLayout title={post.data.title} description={post.data.description}>
  <article>
    <header>
      <h1>{post.data.title}</h1>
      <time datetime={post.data.date.toISOString()}>
        {post.data.date.toLocaleDateString('en-US', {
          year: 'numeric',
          month: 'long',
          day: 'numeric',
        })}
      </time>
    </header>
    <Content />
    {post.data.tags && post.data.tags.length > 0 && (
      <footer>
        <small>Tagged: {post.data.tags.join(', ')}</small>
      </footer>
    )}
  </article>
  <p><a href="/">← back</a></p>
</BaseLayout>
```

The `[...slug]` pattern (with three dots) lets the slug contain forward slashes, so a post at `content/posts/2026/the-title.md` lives at `/posts/2026/the-title/`. Without the dots (`[slug]`), you'd be limited to flat slugs.

`BaseLayout` is the skeleton's layout — `title` and `description` get passed through to its `<head>` for `<title>` and `<meta name="description">`.

### Blog index — `src/pages/index.astro` (or `src/pages/posts/index.astro`)

Two reasonable URL layouts:

- **Blog is the site** (e.g., procrastivity.fm) → index at `/`, posts at `/posts/<slug>/`.
- **Blog is part of a larger site** (e.g., beausimensen.com) → index at `/posts/`, posts at `/posts/<slug>/`.

Same template either way; just the file location differs.

```astro
---
import { getCollection } from 'astro:content';
import BaseLayout from '../layouts/BaseLayout.astro';

const posts = (await getCollection('posts'))
  .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());
---

<BaseLayout title="Posts">
  <h1>Posts</h1>
  <ul>
    {posts.map(post => (
      <li>
        <a href={`/posts/${post.id}/`}>{post.data.title}</a>
        <br />
        <time datetime={post.data.date.toISOString()}>
          {post.data.date.toLocaleDateString('en-US', {
            year: 'numeric',
            month: 'long',
            day: 'numeric',
          })}
        </time>
        {post.data.description && <p>{post.data.description}</p>}
      </li>
    ))}
  </ul>
</BaseLayout>
```

Deliberately minimal. No excerpts of the post body, no thumbnails, no "read more" buttons. The discipline isn't aesthetic — it's that excerpting is a decision and decisions are friction. If you want to grow the index later, do it from the smallest version that works.

If the post count grows past ~50, group by year:

```astro
---
const postsByYear = posts.reduce((acc, post) => {
  const year = post.data.date.getFullYear();
  if (!acc[year]) acc[year] = [];
  acc[year].push(post);
  return acc;
}, {} as Record<number, typeof posts>);
---

{Object.keys(postsByYear).sort().reverse().map(year => (
  <section>
    <h2>{year}</h2>
    <ul>
      {postsByYear[year].map(post => (
        <li>{/* ... */}</li>
      ))}
    </ul>
  </section>
))}
```

That's the only "feature" the index needs to grow into.

### RSS feed — `src/pages/rss.xml.js`

```js
import rss from '@astrojs/rss';
import { getCollection } from 'astro:content';

export async function GET(context) {
  const posts = (await getCollection('posts'))
    .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());

  return rss({
    title: 'Site title',
    description: 'Site description',
    site: context.site,
    items: posts.map(post => ({
      title: post.data.title,
      pubDate: post.data.date,
      description: post.data.description,
      link: `/posts/${post.id}/`,
    })),
  });
}
```

Install: `npm install @astrojs/rss`.

Set `site` in `astro.config.mjs` to the production URL (e.g., `https://procrastivity.fm`). Without it, RSS link URLs are relative and don't work in feed readers.

If you want full content in the feed instead of just descriptions, you can render the markdown to HTML and pass it as `content` — but the simpler description-only feed is plenty for v1.

## Wiring content fetch into the build

The site repo doesn't contain markdown posts. The build fetches them from the content repo before `astro build` runs.

### `scripts/fetch-content.sh`

For **Pattern B** (per-site content repo, the `07`/`08` shape):

```sh
#!/usr/bin/env sh
set -e
rm -rf content
git clone \
  --depth 1 \
  "https://${CONTENT_REPO_TOKEN}@github.com/OWNER/SITE-content.git" \
  content
```

For **Pattern A** (shared content repo, the `06` shape):

```sh
#!/usr/bin/env sh
set -e
rm -rf content
git clone \
  --depth 1 \
  --filter=blob:none \
  --sparse \
  "https://${CONTENT_REPO_TOKEN}@github.com/OWNER/content-repo.git" \
  content
cd content
git sparse-checkout set sites/SITE-NAME
# Symlink so content/posts/ resolves regardless of pattern
cd ..
ln -sf content/sites/SITE-NAME/posts content/posts
```

The symlink at the end is a small kindness — it means `content.config.ts` can always point at `./content/posts` regardless of pattern, and switching patterns later doesn't require rewriting the schema.

Make executable: `chmod +x scripts/fetch-content.sh`.

### `package.json` scripts

```json
{
  "scripts": {
    "fetch-content": "scripts/fetch-content.sh",
    "build": "npm run fetch-content && astro build",
    "dev": "npm run fetch-content && astro dev",
    "preview": "astro preview"
  }
}
```

`dev` also runs the fetch so local development gets real content. If you'd rather develop against a static snapshot (faster iteration when the content repo changes constantly), drop `npm run fetch-content` from `dev` and run it manually when you want fresh content.

### Environment variables

`CONTENT_REPO_TOKEN` is a fine-grained GitHub PAT with **read-only** access to the content repo(s). Separate from the VPS-side PAT (which needs write); this one stays read-only and can have the maximum-allowed expiration (1 year) with low rotation risk.

In Cloudflare Pages: **Project → Settings → Environment Variables → Add Variable**, mark as Secret, set to the token value.

In `.env.local` for local development:

```
CONTENT_REPO_TOKEN=github_pat_...
```

`.gitignore` already excludes `.env.local` per Astro's default `.gitignore`.

## Aesthetic conventions

Match the skeleton (`02`):

- **Plain HTML, plain CSS.** No Tailwind, no component library. The skeleton's `global.css` covers system-font typography; layer per-site styles on top of that.
- **System fonts.** `font-family: ui-sans-serif, system-ui, sans-serif;` (already in the skeleton).
- **Reasonable max-width.** Around 65ch for body copy. Anything wider is uncomfortable to read.
- **Sparing use of color.** A single accent color for links is plenty. Black-and-white prose with one accent reads like a thoughtfully designed personal site; lots of color reads like a corporate blog template.
- **Minimal navigation.** Most blog pages need a logo/title link to home and that's it.

Resist building a "blog theme" until at least three blog sites exist and you've noticed yourself copy-pasting the same CSS.

## What "consistent blogging" actually requires

The unspoken thing in the original ask: a workflow design alone won't make blogging consistent. What it can do is remove enough friction that consistency becomes *possible*. The remaining gap is writing cadence, which is a different problem.

Two small things the workflow can do to help with cadence without trying to solve it:

- **A healthy `drafts/` folder is a feature, not a queue.** Fifteen half-started posts ripening in `drafts/` is the substrate for occasionally finishing one. Don't treat it as a backlog to drain.
- **The friction at the moment of publishing matters more than the friction at the moment of writing.** A perfect editor doesn't help if shipping is a chore. The folder-move publish gesture is deliberately one action because anything more is where personal-blog momentum dies. Optimize ferociously around that point.

## Things to watch for

- **MDX vs plain markdown.** Astro supports MDX (markdown with embedded components). It's tempting for richer posts but breaks the "Obsidian is the source of truth" model — Obsidian doesn't render MDX components and the source files won't preview correctly in your editor. Default: plain markdown for synced-from-Obsidian posts, MDX only for site-specific custom pages that never live in the vault.
- **Wikilinks and other Obsidian-isms.** Configure Obsidian to use standard markdown links (see "Body" section). Wikilinks won't resolve at build time and will render as literal `[[broken text]]`.
- **Date timezones.** Frontmatter dates without timezone info are parsed as midnight UTC. If you post late at night and the displayed date "jumps" a day, that's why. Two fixes: write `date: 2026-05-23T12:00:00-05:00` (explicit timezone) in frontmatter, or accept the small jump. Probably not worth caring about for v1.
- **Slug derivation.** Astro derives the post ID (used as the slug) from the file path relative to the collection base. `content/posts/2026/the-title.md` → ID `2026/the-title`. Filenames are your URL structure; rename files thoughtfully.
- **Renaming a published post.** Changes the URL, which breaks inbound links. If you must rename, add a redirect (Cloudflare Pages supports `_redirects` files in the output).
- **Build caching and content freshness.** Cloudflare Pages builds run `npm run build` from scratch each time, so `fetch-content.sh` runs every build and grabs the latest. No stale-content gotchas at the build layer. (Local dev is a different story — restart `astro dev` after pulling new content.)
- **404 for missing posts.** Astro generates pages only for posts that exist at build time. A link to a post that hasn't been published yet (or was deleted) 404s. This is correct behavior; just be aware that "I pre-linked to a post I haven't written" doesn't work.

## What this doesn't include (deferred)

Explicitly out of scope for v1. Most of these are in `04-deferred-topics.md` already; flagged here so the v1 template doesn't bloat.

- **Tag pages.** Tags are in the frontmatter schema for forward compatibility, but there are no `/tags/<tag>/` index pages. Add when you actually want to browse by tag.
- **Archive pages.** Full chronological archive separate from the main index. Adds when post count justifies.
- **Pagination.** The index renders all posts on one page. Fine until 100+ posts; deal with it then.
- **Search.** Pagefind is the natural pick (runs at build time, free, static). Add when you have enough content to warrant it.
- **Comments.** Probably stay deferred indefinitely. If wanted: Giscus or webmentions, both client-side, both fine on static.
- **Pinned posts.** A `pinned: true` frontmatter flag is trivial to add; defer until needed.
- **Multiple authors.** Schema is currently single-author-implicit (always you). Adding an `author` field later is non-breaking.
- **Series/sequence support.** Posts that are part of a multi-part series. Defer.
- **Reading time estimates.** Computable from word count; add if you want it.
- **Open Graph images.** Per-post social-share images. Worth adding once you actually share posts and notice the ugly default; can be done via a Pages function or build-time generation.

## Open questions

- **Where on the site does the blog live?** `/` (blog is the site), `/posts/`, or `/blog/`? Affects whether `index.astro` is the blog index or a separate landing page. For procrastivity.fm and dabblegangers.com, probably `/`. For beausimensen.com, probably `/posts/` if other content lives at `/`.
- **URL structure: flat or hierarchical?** `/posts/the-title/` vs `/posts/2026/05/the-title/`. The `[...slug].astro` pattern supports both; the choice is purely aesthetic and "what feels right." Flat is fine until post count grows; hierarchical helps with browsing.
- **Should "blog skeleton" be its own template repo?** Right now this is documentation, not a template. If three blog sites end up using the same setup, extracting them into a `procrastivity/astro-blog-bones` template repo (parallel to `astro-bones`) becomes worth it. Until then, copy-paste from this doc is fine.
- **Image handling — relative paths or Astro's `Image` component?** Working baseline is relative `<img>` tags. Switching to optimized images later requires either MDX (incompatible with Obsidian source) or a remark plugin (compatible). Worth revisiting once the answer matters.
- **MDX as a separate content collection?** A `pages/` collection (site-specific MDX pages, not synced from Obsidian) alongside the `posts/` collection (synced markdown) lets you have both without confusing the source-of-truth story. Defer until there's actually an MDX page worth writing.

## Spin-up checklist for a new blog site

Once the patterns above are settled, adding blog capability to a skeleton-based site is roughly:

1. From the new site repo: `npm install @astrojs/rss`
2. Add `src/content.config.ts` with the schema above.
3. Add `src/layouts/PostLayout.astro` (optional — can inline in `[...slug].astro`).
4. Add `src/pages/posts/[...slug].astro` (the single-post template).
5. Add the blog index — either `src/pages/index.astro` (blog at root) or `src/pages/posts/index.astro`.
6. Add `src/pages/rss.xml.js`.
7. Add `scripts/fetch-content.sh` (Pattern A or B variant), `chmod +x`.
8. Update `package.json` scripts to chain fetch → build.
9. Add `content/` to `.gitignore`.
10. In Cloudflare Pages, set `CONTENT_REPO_TOKEN` environment variable.
11. Set `site` in `astro.config.mjs` to the production URL.
12. Push and verify build pulls content and renders.

That's the whole thing. Maybe 30 minutes once you've done it once; the checklist above is the substance of the work.

## Hand-off Doc Index

- `01-triage.md` — master overview, stack decisions, site bucketing
- `02-handoff-skeleton.md` — the Astro skeleton template repo, spin-up flow
- `03-handoff-content-sync.md` — the content sync architecture chat (Options A/B/C)
- `04-deferred-topics.md` — running backlog
- `05-handoff-vps-content-sync.md` — VPS content sync via host-level systemd (Pattern A, single repo)
- `06-handoff-vps-content-sync-docker.md` — VPS content sync via Docker Compose (Pattern A, single repo)
- `07-handoff-vps-content-sync-multi-repo.md` — Docker Compose, Pattern B (per-site repos), local builds
- `08-handoff-vps-content-sync-published-images.md` — Pattern B with images published to GHCR
- `09-handoff-blog-template.md` — this doc; the blog-specific Astro template (content collections, post/index/RSS)
