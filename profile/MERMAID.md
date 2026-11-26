# Mermaid Diagram Examples

This document briefly explains and demonstrates all common Mermaid diagram types supported on GitHub.
[Docs](https://mermaid.js.org/)

---

## 1. Flowchart
Basic node → node diagrams.

```mermaid
flowchart TD
    A[Start] --> B{Decision}
    B -->|Yes| C[Proceed]
    B -->|No| D[Stop]
```

---

## 2. Sequence Diagram
Shows interactions over time.

```mermaid
sequenceDiagram
    participant Client
    participant Server
    Client->>Server: Request
    Server-->>Client: Response
```

---

## 3. Class Diagram (UML)
Structures, classes, inheritance.

```mermaid
classDiagram
    class Person {
        +String name
        +greet()
    }
    Person <|-- Student
```

---

## 4. State Diagram
Finite-state transitions.

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Running : start
    Running --> Idle : stop
```

---

## 5. Entity Relationship Diagram (ERD)
Database-style relations.

```mermaid
erDiagram
    USER ||--o{ ORDER : places
    ORDER ||--|{ PRODUCT : contains
```

---

## 6. Gantt Chart
Timelines, tasks, durations.

```mermaid
gantt
    dateFormat  YYYY-MM-DD
    section Project
    Planning :a1, 2024-01-01, 3d
    Development :after a1, 5d
```

---

## 7. Pie Chart
Simple percentage breakdown.

```mermaid
pie
    title Traffic Breakdown
    "Direct" : 45
    "Search" : 35
    "Referral" : 20
```

---

## 8. Git Graph
Commit/branch visualization.

```mermaid
gitGraph
    commit
    branch feature
    commit
    checkout main
    merge feature
```

---

## 9. Requirement Diagram
High-level requirement → verification mapping.

```mermaid
requirementDiagram
    requirement speed {
      id: 1
      text: Must be fast
    }
    test testSpeed {
      id: T1
      text: Measure runtime
    }
    speed - verifies -> testSpeed
```

---

## 10. Mindmap
Idea organization & hierarchy.

```mermaid
mindmap
  root((Project))
    Development
      Backend
      Frontend
    Marketing
```

---

## 11. Sankey Diagram (Beta)
Flow of values from source → target.

```mermaid
sankey-beta
    A[Input] 0.7:::a --> B[Processing]
    A 0.3:::a --> C[Loss]
```

---

## 12. Timeline Diagram
Chronological events.

```mermaid
timeline
    title Project Roadmap
    2024 : Concept
    2025 : Prototype
    2026 : Release
```

---

## Summary

This file includes demonstrations of:
- Flowcharts  
- Sequence diagrams  
- Class diagrams  
- State diagrams  
- ER diagrams  
- Gantt charts  
- Pie charts  
- Git graphs  
- Requirement diagrams  
- Mindmaps  
- Sankey diagrams  
- Timelines  

All rendered using Mermaid inside Markdown.
