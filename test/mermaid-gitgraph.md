# Mermaid Gitgraph Samples

Examples adapted from https://mermaid.js.org/syntax/gitgraph.html to test diagram rendering.

## Basic

```mermaid
gitGraph
   commit
   commit
   branch develop
   commit
   commit
   commit
   checkout main
   commit
   commit
```

## Custom commit ids

```mermaid
gitGraph
   commit id: "Alpha"
   commit id: "Beta"
   commit id: "Gamma"
```

## Commit types (normal / reverse / highlight)

```mermaid
gitGraph
   commit id: "Normal"
   commit
   commit id: "Reverse" type: REVERSE
   commit
   commit id: "Highlight" type: HIGHLIGHT
   commit
```

## Tags

```mermaid
gitGraph
   commit
   commit id: "Normal" tag: "v1.0.0"
   commit
   commit id: "Reverse" type: REVERSE tag: "RC_1"
   commit
   commit id: "Highlight" type: HIGHLIGHT tag: "8.8.4"
   commit
```

## Branches and merges

```mermaid
gitGraph
   commit
   branch develop
   checkout develop
   commit
   checkout main
   merge develop
   commit
   commit
```

## Cherry-pick

```mermaid
gitGraph
    commit id: "ZERO"
    branch develop
    branch release
    commit id:"A"
    checkout main
    commit id:"ONE"
    checkout develop
    commit id:"B"
    checkout main
    merge develop id:"MERGE"
    commit id:"TWO"
    checkout release
    cherry-pick id:"MERGE" parent:"B"
    commit id:"THREE"
    checkout develop
    commit id:"C"
```

## Orientation: left-to-right (default)

```mermaid
gitGraph LR:
   commit
   branch develop
   commit
   checkout main
   merge develop
   commit
```

## Orientation: top-to-bottom

```mermaid
gitGraph TB:
   commit
   branch develop
   commit
   checkout main
   merge develop
   commit
```
