# JobRunner

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      API Layer                             │
│  (Controllers/Endpoints, DTOs, Services, Validators)       │
│  Composition root: wires up Infrastructure's DI here      │
│         ↓                                                 │

│                    Domain Layer                            │
│  (Entities, Value Objects, Enums — zero dependencies)     │
│         ↑                                                 │
│               Infrastructure Layer                         │
│  (DbContext, External Services — injected into Api        │
│   Services directly, no repository indirection)           │
└─────────────────────────────────────────────────────────────┘
```

## Layers
- **Api**
- **Infrastructure**

## Dependency Flow
- API → Domain (entity types only)
- API → Infrastructure (Services in Api/Services inject DbContext directly — no repository layer)
- Infrastructure → Domain (DbContext maps Domain entities)
- Domain has zero dependency on Infrastructure or EF Core — stays pure
- Tests → All layers

## Setup
```bash
dotnet restore
dotnet build
cd JobRunner.Api
dotnet run
```

## Tests
```bash
dotnet test
```
