---
layout: post
title: "Tauri and rspc: TypeScript integration with Rust"
category: Experiments
tags:
    - tauri
    - rust
    - rspc
    - typescript
---

*TL/DR: Write Rust functions in [rspc], and share type definitions with Typescript.*

As part of my explorations into write-once-run-anywhere app frameworks, I've been playing with [Tauri]
and I must say I'm really impressed by what I'm seeing. I started with a template that uses SvelteKit
and [Skeleton], one of the many UI solutions built upon [Tailwind]. Here's the [link to the template](https://github.com/cogscides/tauri-sveltekit-skeleton-template),
and I generated it with this short command:

```shell
npx degit cogscides/tauri-sveltekit-skeleton-template/example \
  tauri_skeleton_playground
```

Once this is done, running it is just as quick:

```shell
cd tauri_skeleton_playground
mkdir build # if not exists
pnpm i
pnpm tauri dev
```

And this gives us a runnable application!

![Tauri Skeleton Template](/assets/images/tauri_skeleton_template.png)

Let's take a look at how Rust code is connected to Tauri. In `src-tauri/src/main.rs`:

```rust
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![greet])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```
{:file="src-tauri/src/main.rs"}

Looks straightforward enough. How would one call it in Javascript? In `src/lib/Greet.svelte`:

```html
<script lang="ts">
  import { invoke } from '@tauri-apps/api/tauri'
  let name = ''
  let greetMsg = ''
  async function greet() {
    greetMsg = await invoke('greet', { name })
  }
  const handleKeyup = (event: any) => {
    if (event.code == 'Enter') {
      event.preventDefault()
      greet()
      return false
    }
  }
</script>
```
{:file="src/lib/Greet.svelte"}

So far so good. It can be observed that `invoke` takes two things: the name of the command, and
its arguments wrapped in an object. One nitpick however: if one were to inspect the signature
of `invoke`:

```ts
const invoke: <T>(cmd: string, args?: InvokeArgs | undefined) => Promise<T>
```

Depending on who you are, you might have different reactions towards this. *What is even this!?*, you might proclaim,
or if you have worked with Typescript extensively in the past, you might join me and grimace in protest.
*But we know we only have `greet` to call right now!*, so your inner Cool Bear screams out. When we invoke Tauri commands, we usually
have a good (read: definite) idea of what commands are valid, and what arguments each command expects.
It should be more than possible to generate an `invoke` function that knows `greet` is the only valid command,
and there is only one way to call it! If you were keeping up with recent developments
in NPM land, you'd know that [tRPC] is the hot new library that does this very thing for Typescript! Ah, if only there were
such a crate like that for Rust... wait...

![Searching lib.rs for tRPC](/assets/images/search_librs_trpc.png)

Well I did spoil this in the title, but we will use [rspc] to generate Typescript bindings for our Rust commands.
We have only a few small changes to make.

## Integrating with rspc

[rspc] is a thin wrapper around whatever client-server interaction you're already using, and it will output
a Typescript declaration file containing known valid functions and their arguments. It's basically [tRPC] on
steroids, since you don't even have to write type validators! Normally, you use [rspc] alongside traditional
web servers like Axum, Warp or Actix, but the devs have been kind enough to implement adapters for other use-cases,
one of which is Tauri. Let's start from the Rust side by installing the dependencies:

```shell
cargo add rspc --features tauri
```

Following their [instructions](https://rspc.dev/integrations/tauri), let's modify our `main.rs`:

```rust
use std::sync::Arc;
use rspc::Router;

struct Context;

fn main() {
    tauri::Builder::default()
        .plugin(rspc::integrations::tauri::plugin(router(), || Context))
        .run(tauri::generate_context!())
        .expect("error while running tauri application")
}
```
{:file="src-tauri/src/main.rs"}

Let's fill in our router to handle the `greet` request:

```rust
fn router() -> Arc<Router<Context>> {
    let router = Router::new()
        // change the bindings filename to your liking
        .config(rspc::Config::new().export_ts_bindings("../src/bindings.d.ts"))
        .query("greet", |t| t(|_, name: String| greet(&name))))
        .build();
    Arc::new(router)
}
```
{:file="src-tauri/src/main.rs"}

Take note the `export_ts_bindings` config, this will only generate the bindings file at *runtime*
and in debug mode. It might be hard to run this at build-time instead, but we shouldn't worry about
it for now.

With that done, let's run the app again to generate the bindings we wanted:

```shell
pnpm tauri dev
```

If everything goes well, you should get the shiny new `bindings.d.ts` file:

```ts
export type Procedures = {
    queries: 
        { key: "greet", input: string, result: string },
    mutations: never,
    subscriptions: never
};
```
{:file="src/bindings.d.ts"}

Huh... not quite what I expected. You can definitely build *something* that takes this type,
sprinkle some type magic and make it work. But for those of us out there just trying to get by
and learning Typescript is too much to ask, we need a different approach. Luckily,
we haven't yet discussed *how* we're actually calling our new type-safe functions yet, and that's
exactly how we're going to use it. Let's continue with the JS side, where we have new dependencies to install:

```shell
pnpm i @rspc/client @rspc/tauri
```

Create a new file to handle setting up [rspc], for example `src/rpc.ts`:

```ts
import { createClient } from '@rspc/client'
import { TauriTransport } from '@rspc/tauri'

// change "bindings" to be whatever you named your generated bindings
import type { Procedures } from './bindings'

export const api = createClient<Procedures>({
  transport: new TauriTransport()
})
```
{:file="src/rpc.ts"}

And we're set! Before we switch over to [rspc], let's see what `api.query` does:

```ts
const what = api.query
//    ^?: <K extends "greet">(keyAndInput: [key: K, ...input: _inferProcedureHandlerInput<snip>]) => Promise<inferQueryResult<snip>>
```

I promise you it's a lot easier to use than to read! To translate that into English, `api.query`
takes a single *tuple*, the first element of which must be a valid command name and
subsequent elements arguments to the command. Type magic is applied here to automatically infer
the return type and the correct parameters to a command, depending on which one you requested. So putting all that together,
to call our new `greet` command we write:

```ts
const greeting = await api.query(['greet', /*name*/'John'])
//    ^?: string
```

Which looks much more readable now! Now, you might disagree with how this calling convention looks, and you're welcome
to write a wrapper over `query`, but you'll need to be aware of what is going on under the hood to achieve that.

With that out of the way, let's update `Greet.svelte` to use it:

```ts
import { api } from '../rpc'

async function greet() {
  greetMsg = await api.query(['greet', name])
}
```
{:file="src/lib/Greet.svelte"}

To wrap up, let's reorganize our Rust code to make it more extensible:

```rust
// Context is empty for now, but feel free to give it anything else you need.
fn greet(_: Context, name: String) -> String {
    format!("Hello {name}, welcome to the Rust zone. 🦀")
}
 
fn router() -> Arc<Router<Context>> {
    let router = Router::new()
        // change the bindings filename to your liking
        .config(rspc::Config::new().export_ts_bindings("../src/bindings.d.ts"))
        .query("greet", |t| t(greet))
        .build();
    Arc::new(router)
}
```
{:file="src-tauri/src/main.rs"}

And that's that! Let's run our app again using `pnpm tauri dev`, and...

```shell
thread 'main' panicked at 'there is no reactor running, must be called from the context of a Tokio 1.x runtime', /Users/vdinh/.cargo/registry/src/github.com-1ecc6299db9ec823/rspc-0.1.3/src/integrations/tauri.rs:28:13
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

<p style="font-size: 2em">😔</p>

Well, we're living on the cutting edge so things like this are bound to happen. It's possible you're reading this in the future, and everything runs as expected.
There are a few ways to fix this, but to keep it simple I'll bring in a Tokio runtime:

```shell
cargo add tokio --features rt
```

And change `main.rs`:

```rust
fn main() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let _guard = rt.enter();
    tauri::Builder::default()
        .plugin(rspc::integrations::tauri::plugin(router(), || Context))
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```
{:file="src-tauri/src/main.rs"}
  
And surely we're all done! 🎉 Let's try `pnpm tauri dev` again.

![Template with rspc](/assets/images/rspc_template.png)

## Conclusions

Overall, I'm pretty happy with the current state of [Tauri] and that others have built wonderful tools around it.
That Tokio is required for [rspc] to function bugs me a tiny bit, but what has been accomplished here makes me
excited for the future.

[Tauri]: https://tauri.app
[Skeleton]: https://skeleton.dev
[Tailwind]: https://tailwindcss.com
[tRPC]: https://trpc.io
[RSPC]: https://rspc.dev