# Mermaid Sequence Diagram Samples

Examples adapted from https://mermaid.js.org/syntax/sequenceDiagram.html to test diagram rendering.

## Basic

```mermaid
sequenceDiagram
    Alice->>John: Hello John, how are you?
    John-->>Alice: Great!
    Alice-)John: See you later!
```

## Activations and notes

```mermaid
sequenceDiagram
    participant Alice
    participant Bob
    Alice->>+Bob: Hello Bob, how are you?
    Bob-->>-Alice: I am good thanks!
    Note right of Bob: Bob thinks
    Bob->>Alice: I am still good thanks!
```

## Loops and alternatives

```mermaid
sequenceDiagram
    Alice->>Bob: Are you OK?
    loop Every minute
        Bob->>Bob: Self-check
    end
    alt is sick
        Bob->>Alice: Not OK
    else is healthy
        Bob->>Alice: OK
    end
```
