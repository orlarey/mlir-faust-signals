---
title: Un dialecte MLIR pour les signaux FAUST
author: [Yann Orlarey, Pierre Cochard, Stéphane Letz]
titlepage: true
titlepage-color: "a6c5f7"

date: "19 juin 2025"
titlepage-logo: "images/logo-faust.png"
logo-width: 350px
keywords: [my key words]

numbersections: true
secnumdepth: 2


listings-disable-line-numbers: true
listings-no-page-break: true
---

# Introduction

L'objectif de ce document est de proposer un dialecte MLIR dédié à la représentation des signaux FAUST. 

Conformément à la sémantique de FAUST, un signal y est défini comme une fonction du temps. Par exemple, un signal réel est représenté par le type (i32) -> f32 et un signal entier par (i32) -> i32. 

Un point important abordé par ce document est la traduction des expressions récursives dans le cadre SSA de MLIR. Il est traité en introduisant le bloc `FAUST.recursive_block`. Ce bloc encapsule les dépendances circulaires et utilise une opération interne, `FAUST.self_projection`, pour permettre à une définition de faire référence à sa propre sortie future, préservant ainsi la validité de la représentation SSA.

A noter que certains aspects du langage ne sont pas abordés, comme par exemple les wavetables, les read-write tables, les foreign functions, ou les fichiers audio.

# Signaux FAUST en MLIR

Un signal FAUST est une fonction du temps qui associe à chaque instant une valeur. Les instants sont les entiers de $\mathbb{Z}$  et peuvent donc être négatifs. Par convention, les calculs commencent réellement à partir de l'instant 0 et tout signal, avant l'instant $0$, vaut $0$. Cela correspond, en termes audio, au fait que les lignes à retard sont toujours initialisées avec du silence.

On distingue typiquement deux types de signaux : 

- les signaux entiers : $\mathbb{Z}\rightarrow\mathbb{Z}$ ,
- les signaux réels : $\mathbb{Z}\rightarrow\mathbb{R}$. 

Les entiers de $\mathbb{Z}$ sont implémentés par des int 32 bits et les réels de $\mathbb{R}$ par des float 32 bits ou 64 bits, suivant l'option donnée au compilateur. 

Afin de pouvoir exprimer des signaux mutuellement récursifs, on définit des signaux groupés produisant des tuples de valeurs. Par exemple, le signal stéréo `r` produit par une réverbération stéréo aura pour type: $\mathbb{Z}\rightarrow(\mathbb{R}\times\mathbb{R})$. Ces signaux groupés ne sont jamais utilisés en tat que tels, mais toujours via des _projections_. Ainsi `r.0` représente le canal gauche et `r.1` le canal droit de ce signal.

## Types de signaux

Ces types s'expriment de manière native en MLIR. Pour les signaux simples, on aura :

- `(i32) -> i32` pour un signal entier ;
- `(i32) -> f32` ou `(i32) -> f64` pour un signal réel.

Pour les signaux groupés, on aura par exemple :

- `(i32) -> tuple<i32>` pour la sortie d'un compteur entier, utilisé avec la projection `.0`,
- `(i32) -> tuple<f32>` pour la sortie d'un simple IIR, utilisé avec la projection `.0`, 
- `(i32) -> tuple<f32,f32>` pour la sortie d'une réverbération stéréo, utilisé avec les projections `.0` et `.1`,
- `(i32) -> tuple<t0,t1,...>` en général avec `ti` = `i32`, `f32`/`f64` et les
projections `.0`, `.1`, … .

## Signaux primitifs

Les signaux FAUST primitifs sont :

- les signaux constants
  - entiers: par exemple `27`
  - réels: par exemple `0.5`
- les entrées audios de l'application, par exemple : `input(0)`, `input(1)`, ...
- les signaux produits par les éléments d'interface utilisateur :
  - `button("play")`
  - `checkbox("mute")`
  - `hslider("pan", 0, -1, 1, 0.01)`
  - `vslider("gain", 0, 0, 1, 0.01)`

Leur représentation MLIR est la suivante

### Signaux Constants

```
// Constantes entières
%c1 = FAUST.constant 27 : (i32)->i32
%c2 = FAUST.constant -42 : (i32)->i32

// Constantes réelles 
%c3 = FAUST.constant 0.5 : (i32)->f32
%c4 = FAUST.constant 3.141592 : (i32)->f32
```

### Entrées audio

```
// Canaux d'entrée audio
%in0 = FAUST.input 0 : (i32)->f32    // Premier canal
%in1 = FAUST.input 1 : (i32)->f32    // Deuxième canal
%in2 = FAUST.input 2 : (i32)->f32    // Troisième canal
```

### Éléments d'interface utilisateur

Les éléments d'interface utilisateur génèrent des signaux qui changent de valeur selon les actions de l'utilisateur. Ainsi, quand l'utilisateur presse un bouton, le signal produit par ce bouton passe à 1, puis revient à 0 quand l'utilisateur relâche le bouton.

Les paramètres des sliders sont décrits par des attributs de type `f32` ou `f64` suivant les options données au compilateur.

```
// Bouton (génère 0.0 ou 1.0)
%play = FAUST.button "play" : (i32)->f32

// Case à cocher (génère 0.0 ou 1.0, état persistant)
%mute = FAUST.checkbox "mute" : (i32)->f32

// Slider horizontal: label, init, min, max, step
%pan = FAUST.hslider "pan" {init = 0.0 : f32, min = -1.0 : f32, max = 1.0 : f32, step = 0.01 : f32} : (i32)->f32

// Slider vertical
%gain = FAUST.vslider "gain" {init = 0.0 : f32, min = 0.0 : f32, max = 1.0 : f32, step = 0.01 : f32} : (i32)->f32
```

## Description des signaux récursifs

Les définitions récursives sont essentielles pour exprimer filtres IIR, échos, réverbérations et d'une manière générale tout système de rétroaction. 

La traduction MLIR pose des problèmes particuliers pour éviter les dépendances circulaires entre signaux, car MLIR suit une approche SSA (Static Single Assignment) où chaque valeur doit être définie avant d'être utilisée. Ce problème peut être résolu en introduisant des blocs récursifs spécialisés qui encapsulent les références circulaires tout en préservant la forme SSA.

### Syntaxe générale

```mlir
%block_name = FAUST.recursive_block "label" : (i32) -> tuple<T1, T2, ...> {
  // Corps du bloc avec références internes
  %self0 = FAUST.self_projection "label", 0 : (i32) -> T1
  // ...
  FAUST.yield (%sig1, %sig2, ...) : (i32) -> tuple<T1, T2, ...>
}
```

**Éléments clés :**

- **`FAUST.recursive_block`** : Définit un bloc de signaux récursifs avec un nom symbolique
- **`"label"`** : Nom symbolique permettant les auto-références internes
- **`FAUST.self_projection`** : Accède à l'une des projections d'un bloc en cours de définition
- **`FAUST.projection`** : Accède à l'une des projections d'un bloc déjà défini
- **`FAUST.yield`** : Retourne le tuple de signaux produit par le bloc

### Exemple : Compteur récursif

Le défi principal est de traduire des expressions récursives du type `y(t) = 1 + y(t-1)` où `y` apparaît des deux côtés de l'équation. En effet, en MLIR-SSA, une variable ne peut pas être utilisée avant d'être définie.

Voici comment cette définition peut être exprimée en MLIR grâce à un bloc récursif spécialisé :

```mlir
// Définition de la constante 1
%one = FAUST.constant 1 : (i32) -> i32

// Bloc récursif minimal
%counter = FAUST.recursive_block "counter" : (i32) -> tuple<i32> {
  // Projection interne (référence au bloc en cours de définition)
  %y_current = FAUST.self_projection "counter", 0 : (i32) -> i32
  
  // Application du délai pour obtenir y(t-1)
  %y_prev = FAUST.delay %y_current, %one : (i32) -> i32
  
  // Addition : y(t) = y(t-1) + 1
  %y_next = FAUST.add %y_prev, %one : (i32) -> i32
  
  FAUST.yield (%y_next) : (i32) -> tuple<i32>
}

// Projection externe pour utiliser le compteur
%y = FAUST.projection %counter, 0 : (i32) -> i32
```

### Blocs récursifs imbriqués

Pour des systèmes plus complexes, on peut imbriquer plusieurs blocs récursifs :

```mlir
%outer = FAUST.recursive_block "outer" : (i32) -> tuple<i32> {
  %outer_ref = FAUST.self_projection "outer", 0 : (i32) -> i32
  
  %inner = FAUST.recursive_block "inner" : (i32) -> tuple<i32> {
    %inner_ref = FAUST.self_projection "inner", 0 : (i32) -> i32
    %delayed = FAUST.delay %inner_ref, %delay_amt : (i32) -> i32
    %with_outer = FAUST.add %delayed, %outer_ref : (i32) -> i32
    FAUST.yield (%with_outer) : (i32) -> tuple<i32>
  }
  
  %inner_proj = FAUST.projection %inner, 0 : (i32) -> i32
  %result = FAUST.mul %outer_ref, %inner_proj : (i32) -> i32
  FAUST.yield (%result) : (i32) -> tuple<i32>
}
```

# Primitives du langage

## Opérations de conversion de type

Les opérations de cast permettent de convertir entre les types numériques de base.

### Cast vers entier : `FAUST.intcast`

Convertit un signal en représentation entière par troncature.

```mlir
%int_signal = FAUST.intcast %input_signal : (i32) -> i32
```

**Paramètres :**

- `%input_signal` : Signal d'entrée de type `(i32) -> f32`
- Résultat : Signal entier de type `(i32) -> i32`

### Cast vers réel : `FAUST.floatcast`

Convertit un signal en représentation à virgule flottante.

```mlir
%float_signal = FAUST.floatcast %input_signal : (i32) -> f32
```

**Paramètres :**

- `%input_signal` : Signal d'entrée de type `(i32) -> i32`
- Résultat : Signal flottant de type `(i32) -> f32`

### L'opération de délai : `FAUST.delay`

L'opération `FAUST.delay` est fondamentale en FAUST pour introduire des retards dans les signaux. Le premier argument est le signal à retarder et le deuxième argument est le retard exprimé en nombre entier d'échantillons. Si $x$ est le signal que l'on veut retarder et $y$ le retard, alors le signal résultant $z$ est tel que $z(t) = x(t-y(t))$. 

Pour que le retard soit valide, il faut qu'il soit entier $y(t)\in\mathbb{N}$, positif et borné : $\exists m\in\mathbb{N}$ tel que $0\leq y(t) \leq m$

```mlir
%delayed_signal = FAUST.delay %input_signal, %delay_amount : (i32) -> T
```

**Paramètres :**

- `%input_signal` : Le signal à retarder de type `(i32) -> T`
- `%delay_amount` : La quantité de délai, également un signal de type `(i32) -> i32`
- Résultat : Signal retardé de type `(i32) -> T`

## Opérations arithmétiques

Les opérations arithmétiques de base permettent de combiner et transformer les signaux numériquement. Elles requièrent que les deux opérandes soient du même type. Il n'y a pas de promotion automatique - les conversions de type doivent être explicites.

### Addition : `FAUST.add`

```mlir
%result = FAUST.add %signal1, %signal2 : (i32) -> T
```

### Soustraction : `FAUST.sub`

```mlir
%result = FAUST.sub %signal1, %signal2 : (i32) -> T
```

### Multiplication : `FAUST.mul`

```mlir
%result = FAUST.mul %signal1, %signal2 : (i32) -> T
```

### Division : `FAUST.div`

```mlir
%result = FAUST.div %signal1, %signal2 : (i32) -> f32
```

**Spécificité :** La division produit toujours un résultat de type `f32`, même si les deux opérandes sont entiers.

```mlir
// Division entière : résultat automatiquement en float
%int1 = FAUST.constant 7 : (i32) -> i32
%int2 = FAUST.constant 3 : (i32) -> i32
%result = FAUST.div %int1, %int2 : (i32) -> f32  // Résultat = 2.333...
```

### Modulo : `FAUST.mod`

```mlir
%result = FAUST.mod %signal1, %signal2 : (i32) -> T
```

## Opérations unaires

### Valeur absolue : `FAUST.abs`

```mlir
%result = FAUST.abs %signal : (i32) -> T
```

### Négation : `FAUST.neg`

```mlir
%result = FAUST.neg %signal : (i32) -> T
```

### Inverse : `FAUST.inv`

```mlir
%result = FAUST.inv %signal : (i32) -> f32  // 1/x
```

## Opérations de comparaison

Toutes les opérations de comparaison produisent un signal entier (0 pour faux, 1 pour vrai).

### Égalité : `FAUST.eq`

```mlir
%result = FAUST.eq %signal1, %signal2 : (i32) -> i32
```

### Inégalité : `FAUST.ne`

```mlir
%result = FAUST.ne %signal1, %signal2 : (i32) -> i32
```

### Inférieur : `FAUST.lt`

```mlir
%result = FAUST.lt %signal1, %signal2 : (i32) -> i32
```

### Inférieur ou égal : `FAUST.le`

```mlir
%result = FAUST.le %signal1, %signal2 : (i32) -> i32
```

### Supérieur : `FAUST.gt`

```mlir
%result = FAUST.gt %signal1, %signal2 : (i32) -> i32
```

### Supérieur ou égal : `FAUST.ge`

```mlir
%result = FAUST.ge %signal1, %signal2 : (i32) -> i32
```

## Opérations logiques et binaires

### ET logique : `FAUST.and`

```mlir
%result = FAUST.and %signal1, %signal2 : (i32) -> i32
```

### OU logique : `FAUST.or`

```mlir
%result = FAUST.or %signal1, %signal2 : (i32) -> i32
```

### OU exclusif : `FAUST.xor`

```mlir
%result = FAUST.xor %signal1, %signal2 : (i32) -> i32
```

### NON logique : `FAUST.not`

```mlir
%result = FAUST.not %signal : (i32) -> i32
```

### Décalage à gauche : `FAUST.lsh`

```mlir
%result = FAUST.lsh %signal, %shift : (i32) -> i32
```

### Décalage à droite : `FAUST.rsh`

```mlir
%result = FAUST.rsh %signal, %shift : (i32) -> i32
```

## Fonctions trigonométriques

### Sinus : `FAUST.sin`

```mlir
%result = FAUST.sin %signal : (i32) -> f32
```

### Cosinus : `FAUST.cos`

```mlir
%result = FAUST.cos %signal : (i32) -> f32
```

### Tangente : `FAUST.tan`

```mlir
%result = FAUST.tan %signal : (i32) -> f32
```

## Fonctions trigonométriques inverses

### Arc sinus : `FAUST.asin`

```mlir
%result = FAUST.asin %signal : (i32) -> f32
```

### Arc cosinus : `FAUST.acos`

```mlir
%result = FAUST.acos %signal : (i32) -> f32
```

### Arc tangente : `FAUST.atan`

```mlir
%result = FAUST.atan %signal : (i32) -> f32
```

### Arc tangente à deux arguments : `FAUST.atan2`

```mlir
%result = FAUST.atan2 %y, %x : (i32) -> f32
```

## Fonctions hyperboliques

### Sinus hyperbolique : `FAUST.sinh`

```mlir
%result = FAUST.sinh %signal : (i32) -> f32
```

### Cosinus hyperbolique : `FAUST.cosh`

```mlir
%result = FAUST.cosh %signal : (i32) -> f32
```

### Tangente hyperbolique : `FAUST.tanh`

```mlir
%result = FAUST.tanh %signal : (i32) -> f32
```

## Fonctions hyperboliques inverses

### Arc sinus hyperbolique : `FAUST.asinh`

```mlir
%result = FAUST.asinh %signal : (i32) -> f32
```

### Arc cosinus hyperbolique : `FAUST.acosh`

```mlir
%result = FAUST.acosh %signal : (i32) -> f32
```

### Arc tangente hyperbolique : `FAUST.atanh`

```mlir
%result = FAUST.atanh %signal : (i32) -> f32
```

## Fonctions exponentielles et logarithmiques

### Exponentielle : `FAUST.exp`

```mlir
%result = FAUST.exp %signal : (i32) -> f32
```

### Logarithme naturel : `FAUST.log`

```mlir
%result = FAUST.log %signal : (i32) -> f32
```

### Logarithme base 10 : `FAUST.log10`

```mlir
%result = FAUST.log10 %signal : (i32) -> f32
```

### Puissance : `FAUST.pow`

```mlir
%result = FAUST.pow %base, %exponent : (i32) -> f32
```

### Racine carrée : `FAUST.sqrt`

```mlir
%result = FAUST.sqrt %signal : (i32) -> f32
```

## Fonctions d'arrondi et de troncature

### Plafond : `FAUST.ceil`

```mlir
%result = FAUST.ceil %signal : (i32) -> f32
```

### Plancher : `FAUST.floor`

```mlir
%result = FAUST.floor %signal : (i32) -> f32
```

### Arrondi : `FAUST.round`

```mlir
%result = FAUST.round %signal : (i32) -> f32
```

### Arrondi vers l'entier le plus proche : `FAUST.rint`

```mlir
%result = FAUST.rint %signal : (i32) -> f32
```

## Fonctions de sélection

### Minimum : `FAUST.min`

```mlir
%result = FAUST.min %signal1, %signal2 : (i32) -> T
```

### Maximum : `FAUST.max`

```mlir
%result = FAUST.max %signal1, %signal2 : (i32) -> T
```

### Sélection conditionnelle : `FAUST.select2`

```mlir
%result = FAUST.select2 %condition, %else_value, %then_value : (i32) -> T
```

**Sémantique :** Si `%condition != 0`, retourne `%then_value`, sinon `%else_value`.
