---
layout: post
title: "Making Typescript work for you (and your day job)"
category: Experiments
tags:
    - typescript
    - type-theory
    - intermediate
---

<link rel="stylesheet" href="/assets/css/shiki.css">

**UPDATE 12/23:** Contains an [errata](#errata) for some of the points made in this article.

*TL/DR: This is a tutorial for how to make Typescript work for a very obscure usage of Javascript. You can skip ahead to
the [problem statement](#the-problem) and its [solution](#the-solution), but do continue reading for the rationale.*

Hey there, it's been a while. I recently got a new position at Odoo in Buffalo and have
been spending the last few months acclimatizing to the daily grind.
Anyhow, having grown up alongside static languages, I am now
confronted with the task of surviving a mainly dynamic codebase of untyped Python (!) and
Javascript (!!), and least to say it has not been easy.

I enjoyed it when it was [AutoHotkey], when my teeny tiny little script did one and only one thing in particular and was only around
a hundred lines long, but boy does it take a toll on one's psyche to have to *divine* the
meaning of code somebody else wrote. So much so that I wrote an entire LSP server just for
Odoo-specific code! If you happen to also write Odoo code for an extended amount of time,
or even if you are just interested in how LSP servers work, you should check out [odoo-lsp] which is
open source and freely available.

```
; A snippet of AHK code that draws a settings screen
; Its meaning has been lost to time...
GUI_Initialize:
Gui, New
Gui +HwndGuiHwnd
Gui, -MaximizeBox -MinimizeBox

Gui, Add, GroupBox, x12 y9 w230 h190 , Options
Gui, Add, Text, x22 y32 w60 h20 +Center, Input Mode
Gui, Add, DropDownList, x92 y29 w140 Choose%R_InputMode% gUpdate_R_InputMode vR_InputMode AltSubmit, Native Input|Dubeolshift|SCIM Romaja
Gui, Add, Text, x22 y59 w60 h20 +Center, SCIM Table
Gui, Add, Text, x92 y59 w90 h20 vR_CurrentTable, %R_CurrentTable%
Gui, Add, Button, x192 y59 w40 h20 , Load

Gui, Add, CheckBox, x22 y79 w150 h20 Checked%isActive% visActive, Do character conversion
Gui, Add, CheckBox, x22 y99 w150 h20 Checked%R_LeadingSilent% vR_LeadingSilent, Automatic silent ieung (ㅇ)
Gui, Add, CheckBox, x22 y119 w150 h20 Checked%R_VerboseTip% vR_VerboseTip, Display all notifications
Gui, Add, Text, x22 y139 w160 h20 , Windows change refresh delay
Gui, Add, Slider, x22 y159 w210 h30 ToolTip +Range1-30 vR_RefreshDelay, %R_RefreshDelay%
```

With introductions out of the way, let's get into the meat of this article: enhancing dynamic Javascript
codebases with Typescript. You know how the saying goes,
"all happy families are similar, but each unhappy family is unhappy in its own way", and it rings true even here.

If you have been unfortunate enough to have a day job as a web developer pre-ES6, you would know that JS
used to be the Wild West when it comes to programming patterns. Most codebases usually have jQuery as
their sole commonality, and if you're lucky consistent use of functions as constructors, but everyone
and their mom has their own takes on how to do class inheritance and module management. Google has
their `goog.provide`, Node.js went with `module.exports`, and a typical webpage could be using either [IIFE]s,
[AMD modules] or just rawdogging script tags like everyone else.

Safe to say, like every JS codebase
that predates ES6, Odoo made equally as many unique choices. They have their own `odoo.define`
in the vein of IIFEs but also allow importing via `require`, and there remains a large number of "classes"
using a weird type of inheritance called `Class.extend`. Here's how it looks in practice:

```js twoslash
odoo.define('my.module', function (require) {
  var Class = require('web.Class');

  var Foo = Class.extend({
    instanceVar: null,
    /** @constructor */
    init: function() {
      this.bar = 123;
    },
    say: function() {
      console.log(this.instanceVar);
    },
  });

  return Foo;
});
```

As far as legacy patterns go, this one isn't too bad... except it's not the easiest to adapt to modern JS/TS.
I'll list a few reasons why:

**Typescript doesn't understand this:** There's no way Typescript can even begin to understand this.
Even assuming that it looks deceptively similar to AMD modules (beats me, I never used it) it still mixes
concepts from all contemporary styles of module management into this weird, proprietary system.
It's just as bad as `goog.provide`, and necessitates changing the internals of Typescript to accommodate this.
The one saving grace is that Typescript understands CommonJS, which promotes `require` to a built-in function
to do its bidding; the reason anything works in this system.
As an experiment, I wrote a small [Typescript plugin] that hooks up and (tries to) resolve these modules,
but that was more than a year ago when I was still very green and safe to say it didn't work very well.

**Module names are arbitrary:** Mainstream module management systems try to follow some logic to ensure
discoverability: many depend on some manner of filesystem paths or publicly available URLs, and this is
neither. Modules can be whatever name they choose, and there can be multiple of them in a single file.
You can say that grepping is enough to help one find these modules, but I can't be bothered to remember
what goes in some module A and module B and would rather be told what's inside them. Also discoverability
sucks, because it doesn't match what you see on the filesystem.

**`Class.extend` is completely opaque:** Even if `Class` and `Class.extend` somehow happens to be resolved
symbols, when inspecting their types you would discover that they make no sense whatsoever. Although this is as
much a shortcoming of Typescript itself, prototype modifications are usually highly irregular in nature
and requires a decent amount of type magic (foreshadowing) to correctly represent. And of course being
legacy code it doesn't get as much love as it should these days.

It is for these and other reasons that Odoo is slowly moving away from `odoo.define` and adopting
ES6 for their codebase, although some warts remain, such as the need to transpile to `odoo.define`
and modules still being allowed to be given arbitrary names. With (most of) the fundamental modules migrated to ES6,
it was finally time for me to connect the dots and flip the switch on full discoverability within the codebase.

There are two steps to this task: resolving the modules' paths, and properly typing `Class.extend`. The first
is simple enough: I have already done something similar with the aforementioned Typescript plugin, and it
turns out that that was unnecessary. As long as the module was written in ES6 style, I could refer to it with
any name by adding an entry to `compilerOptions.paths` in `tsconfig.json`, and it will be picked up by tsc.
I reused the internals of odoo-lsp to do this, so now all it takes is this one command:

```sh
odoo-lsp tsconfig --addons-path foo,bar,.. > tsconfig.json
```

This will fill out both the `@module/*` modules and the classic "aliased" modules with ease.
The next step, however, stumped me for over a year without a proper solution. Let's take a closer
look at the syntax of `Class.extend` and walk through the reasoning that led me to the solution.

## The Problem

```ts twoslash
declare const Class: {
  extend: Function
};

const Foo = Class.extend({
  // instance variables go here,
  // if they are class variables they go on Foo instead.

  // the canonical constructor
  init(bar = 'asd') {
    this.bar = bar;
  },

  say() {
    console.log(this.bar);
  },
});

// The type we want for Foo
type Foo = {
  // constructor signature, we'll come back to this later
  new (bar?: string): {
    bar?: string;
    say(): void;
  }
}
```

Here's a type puzzle for you: what's the right type for `Class.extend`? And to make it clearer, it does take variadic parameters
that form a [mixin] system, and common usage puts the actual prototype as the last parameter:

```ts twoslash
declare const Class: {
  extend: Function
};
// ---cut---
const Say = {
  name: null,
  greet() {
    if (this.name) {
      console.log(`Hello, my name is ${this.name}`);
    }
  },
}
const AnotherMixin = {};
const Bar = Class.extend(Say, AnotherMixin, { /* .. */ });
```

*You can skip to the solution [here](#the-solution), or otherwise read on for the analysis.*

A good place to start is to form the type around its usage: a function that takes variadic parameters, all of which has to maintain
their types. So here's our first version of `extend`:

```ts twoslash
declare const Class: {
  extend: Extend
}
// ---cut---
// T is the tuple of arguments here:
type Extend = <T extends any[]>(...args: T) => T;
const Foo = Class.extend(123, 'asd');
//    ^?
const Bar = Class.extend(null, {});
//    ^?
```

This first draft is not very useful, but it helps us form a mindset around *how* the types of `T` are to be used. One way is
to think of them as *prototypes*, and later ones override earlier ones. And type intersection is how we combine two types in Typescript,
so let's try that:

```ts twoslash
type Extend = <T extends any[]>(...args: T) => Mixed<T>;

// Combined has both the properties of A and B, where B's win out in case of conflicts.
type Combined<A, B> = A & B;

// What goes here?
type Mixed<T> = {};
```

If you are familiar with Typescript you might know the answer already, but this one part can be considered a gateway into a new world
of type-level metaprogramming to many, so let's go a bit slower. *Recursion* is the keyword: when working with types, we don't get to work
with imperative function calls, but must pattern-match to determine the current shape of our (type) inputs. Another language that does not have
loops built-in and has this same problem is Haskell, where a common strategy employed to work with tuples is to consider their two cases:
they are either empty, or they aren't. When they're non-empty, we have tools to separate the *head* of a tuple from its *tail*, and the tail can be
recursively considered until it's empty.

```haskell
-- a function that takes a list of numbers, and returns a number.
sum :: [Number] -> Number
-- the base case: we have nothing, so just return 0.
sum [] = 0 
-- if non-empty, recursively call sum on the tail and put the results together.
sum (head:tail) = head + sum tail
```

If this is your introduction to functional programming, know that you don't have to leave Typescript to experience it! Most high-level type
libraries use tactics like this, and this is also why you hear people describe Typescript's type system as [Turing](https://github.com/microsoft/TypeScript/issues/14833)
[complete](https://github.com/Dragon-Hatcher/type-system-chess). More importantly,
here is the same function described using the TS type system:

```ts twoslash
// Since we can't add numbers using just types yet, consider this fictional, useless type:
interface Add<A, B> {}
type Sum<T> =
  // infer tells TS to consider if T fits the shape being described, and if so binds the type
  // at that position to Head the same way one binds a value to a variable.
  // The ...infer Tail is syntax for "infer the rest of T's contents, and assign its type to Tail."
  T extends [infer Head, ...infer Tail]
    // recursively apply Sum to Tail
    ? Add<Head, Sum<Tail>>
    // or we got to our base case, in which case just return an empty type.
    : {};
```

This is but one of `infer`'s many capabilities, but already it enables many powerful functional programming patterns.
You can read more about it [here](https://www.typescriptlang.org/docs/handbook/2/conditional-types.html#inferring-within-conditional-types).
With this, we can continue filling in the type of `Mixed`:

```ts twoslash
type Extend = <T extends any[]>(...args: T) => Mixed<T>;

type Mixed<T> =
  T extends [infer Head, ...infer Tail]
    // recursively intersect Head with every element in Tail
    ? Head & Mixed<Tail>
    // until there is nothing, so just an empty type.
    : {};
type Foo = Mixed<[{ foo: boolean }, { bar: number }]>;
//   ^?
```

And we're 80% there! Small problem, however: this is not the right type. What we pass as arguments to `extend` are merely the class's
partial prototypes, and a class should be constructed using `new`! Yet the current `extend` function will only return the prototype for us. How do we represent
a class in terms of Typescript? It's pretty simple actually, but the syntax is definitely not common:

```ts twoslash
interface Class<Proto> {
  new (...args: any[]): Proto;
}
declare const WeirdClass: Class<number>;
const instance: number = new WeirdClass();
```

The `new (...args)` syntax is just like any old function signature, except it denotes that it only makes sense to invoke this function with
the `new` keyword and nothing else. Its return type is how we annotate the type of the *instance*, noting how the instance has nothing to do with
the rest of the type.

You can think of `Class` as a box that holds a prototype, and only when it is called with `new` that an instance of said class is constructed.
Let's use this to complete our first functional draft of `Extend`:

```ts twoslash
type Mixed<T> = T extends [infer Head, ...infer Tail] ? Head & Mixed<Tail> : {};
// ---cut---
interface Class<Proto> {
  new (...args: any[]): Proto;
}
type Extend = <T extends any[]>(...args: T) => Class<Mixed<T>>;
```

Now when we call `new Foo`, it will give us the proper type:

```ts twoslash
type Mixed<T> = T extends [infer Head, ...infer Tail] ? Head & Mixed<Tail> : {};
interface Class<Proto> { new (...args: any[]): Proto; }
type Extend = <T extends any[]>(...args: T) => Class<Mixed<T>>;
declare const Class: { extend: Extend }
// ---cut---
const Foo = Class.extend({
  foo: 123,
  say() {  },
});
const foo = new Foo();
foo.foo;
//  ^?
foo.say;
//  ^?
```

That works! Except when you try to use `Foo` as a mixin, which absolutely fails.

```ts twoslash
// @errors: 2339
type Mixed<T> = T extends [infer Head, ...infer Tail] ? Head & Mixed<Tail> : {};
interface Class<Proto> { new (...args: any[]): Proto; }
type Extend = <T extends any[]>(...args: T) => Class<Mixed<T>>;
declare const Class: { extend: Extend }
const Foo = Class.extend({ foo: 123, say() {  }, });
// ---cut---
const Bar = Class.extend(Foo, { 
  bar: null,
});
const bar = new Bar();
bar.bar;
//  ^?
bar.foo;
```

The reason `Bar` did not inherit `Foo.foo` is that when we put them inside `Mixed`, we were
mixing together the prototype with the class of `Foo` itself, when what we wanted was only `Foo`'s prototype!
Here's how to fix it:

```ts twoslash
declare const Class: { extend: Extend }
interface Class<Proto> {
  new (...args: any[]): Proto;
}
type Extend = <T extends any[]>(...args: T) => Class<Mixed<T>>;
// ---cut---
// infer works here too, to extract the prototype of Class.
// you can also call this "unboxing" the Class.
type ProtoOf<T> = T extends Class<infer Proto> ? Proto : T;
type Mixed<T> = T extends [infer Head, ...infer Tail]
  // If Head is a class, we get its prototype, otherwise we mix in Head itself.
  ? ProtoOf<Head> & Mixed<Tail>
  : {};

const Foo = Class.extend({
  foo: 123,
  say() {  },
});

const Bar = Class.extend(Foo, { 
  bar: null,
});

const bar = new Bar();
// this works!
bar.foo;
//  ^?
```

Hopefully by this point you can begin to see how truly powerful Typescript's `infer` really is.
And this gives us the first feature-complete definition of `Extend`, one that you can slap right in
your codebase and gain autocompletion everywhere! Right?

## The Year-Long Search

For the most part, yes. But if you were to use this type in anger, you will quickly come up against
one of its drawbacks:

```ts twoslash
// @errors: 2339
declare const Class: { extend: Extend }
interface Class<Proto> { new (...args: any[]): Proto; }
type ProtoOf<T> = T extends Class<infer Proto> ? Proto : T;
type Mixed<T> = T extends [infer Head, ...infer Tail] ? ProtoOf<Head> & Mixed<Tail> : {};
type Extend = <T extends any[]>(...args: T) => Class<Mixed<T>>;
// ---cut---
// Let's bring back the mock mixin from earlier
const Say = {
  name: null,
  greet() {
    if (this.name) {
      console.log(`Hello, my name is ${this.name}`);
    }
  },
}
// We mix in Say's properties and methods with Foo,
// the new type is just as we expected...
const Foo = Class.extend(Say, {
//    ^?
  sayHi() {
    // ...but none of its properties are accessible from within these methods!
    this.greet();
    this.name;
  },
});
```

Suffice to say, it is completely oblivious to `Say`'s contributions to the overall prototype.
The type of `this` that you see here is merely a reflection of the object literal itself,
and any properties/methods it may have. If we want `extend` to work exactly the way we want,
we'll have to be a bit more creative.

Let's think about what we want `this` to be, in the context of a method. It should be:

- The object literal, so that any properties/methods present on the object will be accessible via `this` itself.
- The prototypes of the classes, or the mixins themselves, and this has to apply to *all* of them at the same time!
- The prototype of the class being extended.

You can already see that the `this` keyword is extremely overloaded here! It's a small reason why mixins aren't a popular pattern
in Typescript, because of its ability to change the type so dramatically.
Nevertheless, how do we even annotate the type of `this` for all of an object's methods? Is that even possible?
Before I show you my first attempt, let's make a concession that the *primary prototype* i.e. the object literal must
be at the end to qualify for `this`-inheritance. Let's see it:

```ts twoslash
// @errors: 2353
interface Class<Proto> { new (...args: any[]): Proto; }
type ProtoOf<T> = T extends Class<infer Proto> ? Proto : T;
type Mixed<T> = T extends [infer Head, ...infer Tail] ? ProtoOf<Head> & Mixed<Tail> : {};
declare const Class: { extend: Extend }
const Say = { name: null, greet() { }, }
// ---cut---
type Extend<
  // We keep the base prototype around; this is basically ProtoOf<Foo> when Foo.extend() is called.
  Base = {}
> = <
  // Despite being called Mixins, it can contain classes as well.
  Mixins extends any[],
  // Bit of a mess here, but let's unpack it:
  // We want Proto to match a specific pattern
  // [Base, ...Mixins] simply combines all the relevant mixins/classes
  // Mixed<_> actually does the job of intersecting them
  // WithThis<_> will be explained later, but it performs the task of augmenting `this`
  Proto extends WithThis<Mixed<[Base, ...Mixins]>>
>(
  // all the arguments, packed together in a nice varargs
  // note that our primary prototype must sit at the end
  // and this requires that there be at least one argument.
  ...protos: [...Mixins, Proto]
) =>
  // Finally, do the same thing we did with Proto, only this time we include Proto at the end.
  Class<Mixed<[Base, ...Mixins, Proto]>>;
// Dummy type for now
type WithThis<T> = T;

const Foo = Class.extend(Say, {
  sayHi() {
    this.greet();
    this.name;
  },
});
```

The naive expectation is that this would work, because `Proto extends` basically constrains `Proto`
to be a specific type, that is the combination of `Base` and all of the `Mixins`. But this doesn't work.
The reason why, I never got to discover because I had to abandon this experiment due to time constraints
which eventually took me away from this project. Months went by, my mind kept tugging on this particular
thread without end, and for more than a year there was effectively no progress. I like to blame my inexperience
for being unable to solve this particular puzzle, but at the time I truly did not realize that things are this way
because of Typescript's gotchas around type parameters in different positions.

You the reader, however, shall be spared from the agony that is waiting for a full year before reaching a certain
intuition that would untangle this puzzle. Pause here if you'd like to work it out yourself. Ready for the reveal?

---

You see, `extends` is one of the more nebulous keywords in Typescript because
it does the exact opposite thing its namesake describes: it *constrains* types! Take this for example:

```ts twoslash
// @errors: 2345
function bar<T extends 'foo' | 'bar'>(arg: T) {
  // the concrete type of 'arg' is T
  // which then can either be 'foo' or 'bar'
  // this is the guarantee that Typescript gives us, because we asked for it
  const _: 'foo' | 'bar' = arg;
}

// There is no issue calling bar like this, when they match the constraints...
bar('foo');
bar('bar');

// but this wouldn't work:
bar('baz');
```

It is plain to see in this example that it would be impossible to call `bar` with any other arguments other than the ones prescribed.
However, things get tricky when `T` extends a complex object, as was the case in the previous implementation of `Extend`.
Here's a miniature version for clarity:

```ts twoslash
// @errors: 2345
interface A {
  a: string;
}

interface B {
  b: number;
}

function bar<T extends A & B>(arg: T) {
  arg.a;
  arg.b;
}

// does not extend B
bar({ a: 'asd' });
// does not extend A
bar({ b: 123 });

// call typechecks <=> arg extends both A and B
bar({ a: 'asd', b: 123 });
```

Can you see the issue? In the latter case `arg extends A & B` so it must satisfy both `A` and `B`, meaning it must contain all of
their constituent properties and methods! In the case of `extend`, we only have a primary prototype we would like to somehow
automagically *augment* with the types of its mixins, not force the end-user to supply a type that satisfies all of `Base` and
`Mixins`! What's interesting is that you can see the same dichotomy between `class extends` and `implements`, where our `T extends`
acts more like an `implements` that forces the end-user to supply all of the properties that make up a certain interface.

Alright, enough type theory for one day. The intuition is that `T extends` does the opposite of what we want it to do. So what's the alternative?
This article is already getting a bit long, so I'll show you the final solution that does work in the most general of cases.

## The Solution

```ts twoslash
interface Class<Proto> { new (...args: any[]): Proto; }
type ProtoOf<T> = T extends Class<infer Proto> ? Proto : T;
type Mixed<T> = T extends [infer Head, ...infer Tail] ? ProtoOf<Head> & Mixed<Tail> : {};
const Say = { name: null, greet() { } }
declare const Class: { extend: Extend }
// ---cut---
type Extend<Base = {}> =
  // Slightly compacted version of the previous solution.
  // Of note is the freestanding Proto
  // It has no constraints, so that it can be anything...
  // And we force the final vararg to assume a particular shape using WithThis.
  // At no point in time did we force Proto to be anything!
  <Mixins extends any[], Proto>(...protos: [...Mixins, WithThis<Proto, Mixed<[Base, ...Mixins]>>]) =>
    Class<Mixed<[Base, ...Mixins, Proto]>>;

// We use a mapped type to transform Proto's methods to take a new 'this' parameter.
type WithThis<Proto, Base> = {
  [K in keyof Proto]:
    // Completely destructure a method into its parameters and output
    Proto[K] extends (..._: infer Args) => infer Output
      // then rejoin them, also annotating 'this' as the first meta-parameter
      ? (this: Base & Proto, ..._: Args) => Output
      // properties pass through unmodified
      : Proto[K]
}

// Finally use it!
const Foo = Class.extend(Say, {
  sayHi() {
    this.greet();
    //   ^?
  },
});
```

The beauty of `Extend` is that type inference just works, so that `this` is always the correct type no matter the situation.
The only remaining problem is overridden methods, and again Odoo follows the convention of `this._super` referencing the overriden method.
We can use the same trick to inject a special version of `this` whose `_super` is different for every method, but only
if the overriden method actually exists:

```ts twoslash
declare const Class: { extend: Extend }
interface Class<Proto> { new (...args: any[]): Proto; }
type ProtoOf<T> = T extends Class<infer Proto> ? Proto : T;
type Mixed<T> = T extends [infer Head, ...infer Tail] ? ProtoOf<Head> & Mixed<Tail> : {};
type Extend<Base = {}> =
  <Mixins extends any[], Proto>(...protos: [...Mixins, WithThis<Proto, Mixed<[Base, ...Mixins]>>]) =>
    Class<Mixed<[Base, ...Mixins, Proto]>>;
const Say = { name: null, greet() { } }
// ---cut---
type WithThis<Proto, Base> = {
  [K in keyof Proto]:
    Proto[K] extends (..._: infer Args) => infer Output
      ? (this: WithSuper<Proto, Base, K>, ..._: Args) => Output
      : Proto[K];
}

type WithSuper<Proto, Base, Method> =
  // Is Base[Method] well-formed?
  Method extends keyof Base
    // And a function?
    ? Base[Method] extends (..._: infer Args) => infer Output
      // Then _super shall be that exact type.
      ? Base & Proto & { _super(..._: Args): Output }
      // Otherwise, just combine the two.
      : Base & Proto
    : Base & Proto;

const Foo = Class.extend(Say, {
  // _super came from Say.greet, so this works
  greet() {
    return this._super();
    //          ^?
  },
});
```

Even this technique has its limits. One consequence of having to inject `this` while `Proto` is still being inferred
is that you will have to annotate all your return types that are not `void`. Let's see why:

```ts twoslash
declare const Class: { extend: Extend }
interface Class<Proto> { new (...args: any[]): Proto; extend: Extend<Proto>; }
type ProtoOf<T> = T extends Class<infer Proto> ? Proto : T;
type Mixed<T> = T extends [infer Head, ...infer Tail] ? ProtoOf<Head> & Mixed<Tail> : {};
type Extend<Base = {}> =
  <Mixins extends any[], Proto>(...protos: [...Mixins, WithThis<Proto, Mixed<[Base, ...Mixins]>>]) =>
    Class<Mixed<[Base, ...Mixins, Proto]>>;
type WithSuper<Proto, Base, Method> =
  Method extends keyof Base
    ? Base[Method] extends (..._: infer Args) => infer Output
      ? Base & Proto & { _super(..._: Args): Output }
      : Base & Proto
    : Base & Proto;
// ---cut---
// Let's take a look at WithThis again
type WithThis<Proto, Base> = {
  [K in keyof Proto]:
    Proto[K] extends (..._: infer Args) => infer Output
      ? (this: WithSuper<Proto, Base, K>, ..._: Args) => Output
      : Proto[K];
} 

const Counter = Class.extend({
  value: 0,
  next() {
    return this.value++;
  },
});

const Foo = Counter.extend({
  next() {
  //^?
    return this._super() + 1;
  }
});
```

Even though it would be trivial to infer `this._super() + 1` to be `number` and assign that to the return type of
`Foo.next`, Typescript cannot decipher it at all and falls back to `any`.
A rundown of what happens when `Foo.next`'s return type is being inferred:

- `next`'s return type depends on the expression `this._super() + 1`
- Instead of short-circuiting here because `object + 1` always[\*](#errata) returns `number`, it evaluates `this._super()`
- ...which evaluates `this._super`
- ...which evaluates `this`, whose type is `WithThis<..>`
- `WithThis<..>` has a clause `Proto[K] extends (..) => infer Output`, which is the type in question.
  There's nothing to infer since Typescript is still trying to infer `Output`.
- A loop is formed when attempting to resolve `Foo.next`'s return type, so bail out.

This is only a high-level observation that is not yet backed with proper code review, but it should now be clearer
why the return type is not automatically inferred. I might make an update should a new solution be found, or
Typescript is updated to handle this pattern. For now, here is the [complete listing].

## The Twist

...Aha! Gotcha, didn't I? When you thought it was the home stretch, but apparently there are still mysteries to be solved and bugs to be squashed.
You see, Typescript's type magic comes at a cost, not only to the code's readability (and arguably the reader's sanity) but also to the type checker's complexity, and since it was built
by mere mortals it also comes with all the attendant limits that mortals cannot hope to overcome with ease. If you were successful in annotating the type
of `Class.extend` and witness its usage around a typical Odoo codebase, you will catch glimpses of certain oddities.

```ts
import Widget from 'web.Widget';

publicRegistry.SomeWidget = Widget.extend({
  selector: ['..'],
  fooBar() {
    this;
    // ^?: never
  }
});
```

If you were unlucky enough to encouter such cases where the type checker simply stopped any pretenses of coherence, try running `tsc --noEmit` and you might be surprised by what you can see:

```
Error: Debug Failure. Expected [object Object] === [object Object]. Parameter symbol already has a cached type which differs from newly assigned type
```

[Messages like this](https://github.com/microsoft/TypeScript/issues/50773) are a good stopping point for the day. No, really. Pat yourself on the back, because you deserve it and your suffering will be a great
contribution towards the advancement of humanity as a whole, so on and so forth. In the industry we call these *internal compiler errors* or ICEs for short,
because boy does it always take a lot of time to break the ice! (sorry not sorry)

Regardless, it seems that our little experiment has managed to reach the limits of what Typescript is presently capable of. Perhaps I might revisit this
particular topic in the future, preferably after me or someone else opening a PR to fix this wart in what I can only otherwise consider one of my favorite languages.
And that was the story of how I saved my relationship with my day job, and how you can too with the right amount of 🌈 Type Magic.

## Errata

- `object + 1` does not in fact always return `number`, because it depends on the type of `object`. Here's a demonstration:

```ts twoslash
// @errors: 2365
function foo(): string {
  // The add operator is well-formed for `string` and `number`,
  // i.e. it always returns a string.
  return 'asd' + 1;
}

function bar(val: object) {
  // Typescript intentionally does not allow addition between `object` and `number`,
  // but runtime behavior is well-defined in the spec so this would be a numeric operation.
  return val + 1;
}
```

If one were to follow the specs to a T, the type of the addition operator depends on
its operands, or if not possible to determine statically `string | number` because of course it
also concatenates strings where possible. If you're interested, here's how the specs allow for
addition between two unrelated types via [ApplyStringOrNumericBinaryOperator](https://262.ecma-international.org/12.0/#sec-applystringornumericbinaryoperator).

[AutoHotkey]: https://www.autohotkey.com
[odoo-lsp]: https://github.com/Desdaemon/odoo-lsp
[IIFE]: https://developer.mozilla.org/en-US/docs/Glossary/IIFE
[AMD modules]: https://requirejs.org/docs/whyamd.html#amd
[Typescript plugin]: https://github.com/Desdaemon/odoo-import
[mixin]: https://en.wikipedia.org/wiki/Mixin
[complete listing]: https://www.typescriptlang.org/play?#code/CYUwxgNghgTiAEYD2A7AzgF3gYWmtAXPAN4BQ88IAHhiCsEQKI13ADcpAvh6QJYq0YAMyhgEuKPgA8ABRhIMSAHwly8FCADu8ABQA6A7ADmhHIpgBBGCdnzFSgJRE5CpBwrVa9Ji3q3XShycpKQYAJ4ADgguigDyQlIAKioAvPCJlL7AaDh4aFL8QiAw8DHK8AD8pXZI8ESJPOFR8ACyvFQgwEmp6Zle2fAA2oXF8AASIFDAADTwBnojJYlQvBAAumpVZfFSE1MqAGSt7Z1JKxBKakTE3CFNCMz9UgBCkghpNz1SbVT8OZ6sHJQFBhQZrWZlJQ6NTzCI1UyDeY-P6zADqvAwAAtEpjePkyrMfqdBq80CBZkj2n81kolBsHPAUioJNIiV0SW8KQZkegITUaYE7pEEOisTi8f5FLNSSAemQKIMANLwfjwADWIDCSCE1Vca2cNSVaz6gN08wA+kRFvArCYGUyVSgiiVYgBXDARd1qChVHRYvFEUWYgDKrqiMElSGlnPgiqUXL0lpt1jQ9pUbo9XooFANriNQUawvgQdD4cj0bJhJAWKQwB6LWrmNrJvoOQ1Wp1Ms28BlgwbNeAxoBrbNBiT1ttqcZKmtGc9GG9lR7b3gRzKq5I8HNaDDxX0Y6Ik6c8Dn7vgwWzdWXZI3ZSu14Qa5qPAA9C+bSh4FNgBjeKgoBA8D3EBtTWsg6AYDArpgOYX7WK6AC2dAYGgoRFtg5iTpGPTrsOAzEI6GL7omVpOqMR5EMCYTnt2k73mCr7vq6aBQEYCCgAhSAhOBmA4EgroCKMaQsmgeh4To8rwAAbgBrogEQAAM0xqPwREyRAcmMvACkMpJFD+qJ6maWkRkgO457KRQGg0DoumLnAGCujAn4GXopkANTueZnDKZwDg8DxWBCEgtQpGob4UAAehUagaNo2D8YJMC2eZEXwNFpBAA
