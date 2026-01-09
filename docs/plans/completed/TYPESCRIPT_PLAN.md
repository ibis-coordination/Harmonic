# TypeScript Conversion Plan

This document outlines the plan for converting the existing JavaScript code to TypeScript.

## Current State

### JavaScript Inventory

The codebase has **29 JavaScript files** with approximately **1,334 lines of code**:

| Category | Files | Lines | Complexity |
|----------|-------|-------|------------|
| Stimulus Controllers | 22 | ~1,100 | Medium-High |
| Utility Modules | 5 | ~180 | Low |
| Entry Points | 2 | ~54 | Low |

### Build System

Currently using **importmap-rails** (not a bundler):
- JavaScript modules loaded via ES module imports
- External dependencies served from jspm CDN
- No build step - files served directly to browser

```ruby
# config/importmap.rb
pin "application", preload: true
pin "@hotwired/stimulus", to: "https://ga.jspm.io/npm:@hotwired/stimulus@3.2.1/dist/stimulus.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "cropperjs", to: "https://ga.jspm.io/npm:cropperjs@1.6.2/dist/cropper.js"
pin "date-fns", to: "https://ga.jspm.io/npm:date-fns@3.6.0/index.mjs"
```

### External Dependencies

| Package | Usage |
|---------|-------|
| @hotwired/stimulus | Controller framework |
| @hotwired/turbo-rails | Page navigation |
| stimulus-use | Controller utilities (useClickOutside, useDebounce) |
| cropperjs | Image cropping |
| date-fns | Date formatting |
| hotkeys-js | Keyboard shortcuts |
| trix | Rich text editor |
| @rails/actiontext | Action Text integration |

### Controller Complexity

**High complexity** (50+ lines):
- `decision_controller.js` (148 lines) - voting, options, approvals
- `image_upload_controller.js` (135 lines) - cropping, file handling
- `draft_controller.js` (95 lines) - autosave, dirty tracking
- `action_interface_controller.js` (80 lines) - LLM action interface

**Medium complexity** (20-50 lines):
- `local_time_controller.js` (45 lines)
- `dropdown_controller.js` (40 lines)
- `copy_controller.js` (35 lines)

**Low complexity** (<20 lines):
- Most other controllers

## Challenge: importmap-rails and TypeScript

**The core problem**: importmap-rails serves JavaScript files directly to the browser without a build step. TypeScript requires compilation to JavaScript.

### Options

#### Option A: Keep importmap-rails + Add TypeScript Compilation

Add a TypeScript compilation step that outputs to a directory served by importmap:

```
app/javascript/          # TypeScript source
  └── controllers/
      └── decision_controller.ts

app/assets/builds/       # Compiled JavaScript (gitignored)
  └── controllers/
      └── decision_controller.js
```

**Pros:**
- Minimal change to existing architecture
- Keep importmap's simplicity for external deps

**Cons:**
- Awkward hybrid approach
- Need to manage two directories
- importmap-rails not designed for this

#### Option B: Switch to jsbundling-rails with esbuild (Recommended)

Replace importmap-rails with jsbundling-rails using esbuild:

```bash
# Install jsbundling-rails
./bin/rails javascript:install:esbuild
```

**Pros:**
- First-class TypeScript support
- Fast compilation (esbuild)
- Better source maps
- Can use npm packages directly
- Modern, well-supported approach

**Cons:**
- Requires build step
- Slightly more complex development setup
- Need to update deployment process

#### Option C: Switch to Vite Rails

Use vite-ruby gem for modern frontend tooling:

**Pros:**
- Excellent TypeScript support
- Hot module replacement
- Modern tooling

**Cons:**
- Biggest change to existing setup
- Overkill for current codebase size

### Recommendation

**Option B: jsbundling-rails with esbuild** is the recommended approach because:
1. Native TypeScript support without workarounds
2. esbuild is extremely fast (~10ms builds)
3. Rails-supported solution with clear upgrade path
4. Can import npm packages normally

## Implementation Plan

### Phase 1: Build System Migration

**Goal**: Switch from importmap-rails to jsbundling-rails with esbuild

1. Install jsbundling-rails:
   ```bash
   bundle add jsbundling-rails
   ./bin/rails javascript:install:esbuild
   ```

2. Configure esbuild for TypeScript:
   ```javascript
   // esbuild.config.js
   const esbuild = require('esbuild');

   esbuild.build({
     entryPoints: ['app/javascript/application.ts'],
     bundle: true,
     sourcemap: true,
     outdir: 'app/assets/builds',
     loader: { '.ts': 'ts' },
   });
   ```

3. Add TypeScript configuration:
   ```json
   // tsconfig.json
   {
     "compilerOptions": {
       "target": "ES2020",
       "module": "ESNext",
       "moduleResolution": "bundler",
       "strict": true,
       "noImplicitAny": true,
       "strictNullChecks": true,
       "esModuleInterop": true,
       "skipLibCheck": true,
       "forceConsistentCasingInFileNames": true,
       "declaration": false,
       "outDir": "./app/assets/builds",
       "rootDir": "./app/javascript",
       "baseUrl": ".",
       "paths": {
         "controllers/*": ["app/javascript/controllers/*"]
       }
     },
     "include": ["app/javascript/**/*"],
     "exclude": ["node_modules"]
   }
   ```

4. Install TypeScript and type definitions:
   ```bash
   npm install --save-dev typescript @types/node
   npm install --save-dev @hotwired/stimulus @hotwired/turbo-rails
   npm install cropperjs date-fns hotkeys-js
   ```

5. Remove importmap-rails:
   - Remove `gem 'importmap-rails'` from Gemfile
   - Remove `config/importmap.rb`
   - Update `app/views/layouts/application.html.erb` to use new asset tag

6. Update Docker and CI:
   - Add Node.js to Dockerfile if not present
   - Add `npm install` and build step to CI
   - Update `scripts/setup.sh`

### Phase 2: TypeScript Configuration

**Goal**: Set up TypeScript with appropriate strictness

Start with moderate strictness, increase later:

```json
{
  "compilerOptions": {
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true
  }
}
```

Add Stimulus type definitions:
```typescript
// app/javascript/types/stimulus.d.ts
import { Controller } from "@hotwired/stimulus";

declare module "@hotwired/stimulus" {
  interface Controller {
    // Add any custom controller extensions
  }
}
```

### Phase 3: Convert Entry Points

**Goal**: Convert non-controller files first (lowest complexity)

Files to convert:
1. `application.js` → `application.ts`
2. `controllers/index.js` → `controllers/index.ts`
3. `polling_trigger_event.js` → `polling_trigger_event.ts`
4. `image_cropper.js` → `image_cropper.ts`
5. `local_time.js` → `local_time.ts`

### Phase 4: Convert Simple Controllers

**Goal**: Convert low-complexity controllers

Order (by complexity, simplest first):
1. `navigation_controller.js` (5 lines)
2. `flash_controller.js` (8 lines)
3. `scroll_controller.js` (10 lines)
4. `sidebar_controller.js` (12 lines)
5. `studio_form_controller.js` (15 lines)
6. `collapsible_controller.js` (18 lines)
7. `modal_controller.js` (20 lines)
8. `clipboard_controller.js` (22 lines)

### Phase 5: Convert Medium Controllers

**Goal**: Convert medium-complexity controllers

1. `copy_controller.js` (35 lines)
2. `dropdown_controller.js` (40 lines)
3. `local_time_controller.js` (45 lines)
4. `keyboard_shortcuts_controller.js` (50 lines)
5. `form_validation_controller.js` (55 lines)

### Phase 6: Convert Complex Controllers

**Goal**: Convert high-complexity controllers with full typing

1. `action_interface_controller.js` (80 lines)
2. `draft_controller.js` (95 lines)
3. `image_upload_controller.js` (135 lines)
4. `decision_controller.js` (148 lines)

### Phase 7: Add CI Integration

**Goal**: Ensure TypeScript errors block CI

1. Add type check to GitHub Actions:
   ```yaml
   - name: TypeScript type check
     run: npx tsc --noEmit
   ```

2. Add pre-commit hook:
   ```bash
   echo "Running TypeScript type check..."
   if npx tsc --noEmit > /dev/null 2>&1; then
       echo "✓ TypeScript type check passed"
   else
       echo "✗ TypeScript type check failed."
       exit 1
   fi
   ```

## Stimulus Controller Typing Patterns

### Basic Controller Pattern

```typescript
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "output"] as const;

  declare readonly inputTarget: HTMLInputElement;
  declare readonly outputTarget: HTMLElement;
  declare readonly hasInputTarget: boolean;

  static values = {
    url: String,
    count: Number,
    active: Boolean,
  };

  declare urlValue: string;
  declare countValue: number;
  declare activeValue: boolean;

  connect(): void {
    // initialization
  }

  handleClick(event: Event): void {
    event.preventDefault();
    // handle click
  }
}
```

### With stimulus-use

```typescript
import { Controller } from "@hotwired/stimulus";
import { useClickOutside, useDebounce } from "stimulus-use";

export default class extends Controller {
  static debounces = ["search"];

  connect(): void {
    useClickOutside(this);
    useDebounce(this);
  }

  clickOutside(event: Event): void {
    this.close();
  }

  search(): void {
    // debounced search
  }

  private close(): void {
    // implementation
  }
}
```

## File Mapping

| Current File | New File |
|--------------|----------|
| `app/javascript/application.js` | `app/javascript/application.ts` |
| `app/javascript/controllers/index.js` | `app/javascript/controllers/index.ts` |
| `app/javascript/controllers/*_controller.js` | `app/javascript/controllers/*_controller.ts` |
| `app/javascript/*.js` | `app/javascript/*.ts` |

## Success Criteria

- [x] All JavaScript files converted to TypeScript
- [x] TypeScript compilation passes with strict mode
- [x] No `any` types (except where unavoidable)
- [x] All Stimulus targets and values properly typed
- [x] CI blocks on TypeScript errors
- [x] Development workflow documented (see CLAUDE.md)
- [x] No runtime regressions
- [x] Frontend testing with Vitest (17 tests across 5 controllers)

## Non-Goals

- Converting embedded JavaScript in ERB templates (minimal, keep as-is)
- Adding React/Vue/other frameworks
- Major UI refactoring

## Dependencies on Other Work

- None - can proceed independently of controller refactoring plan
- TypeScript conversion may inform controller refactoring patterns

## Risks

1. **stimulus-use typing** - May need custom type declarations
2. **Third-party types** - Some CDN packages may lack types
3. **Build time impact** - esbuild is fast, but adds a step
4. **Developer experience** - Team needs TypeScript familiarity

## Resources

- [Stimulus Handbook](https://stimulus.hotwired.dev/handbook/introduction)
- [jsbundling-rails](https://github.com/rails/jsbundling-rails)
- [TypeScript Handbook](https://www.typescriptlang.org/docs/handbook/)
- [stimulus-use TypeScript](https://stimulus-use.github.io/stimulus-use/)
