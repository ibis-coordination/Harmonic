import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import functional from "eslint-plugin-functional";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  ...tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
      globals: {
        ...globals.browser,
      },
    },
  },
  {
    plugins: {
      "react-hooks": reactHooks,
      functional,
    },
    rules: {
      // React hooks rules
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",

      // Functional programming rules - no mutation
      "functional/immutable-data": ["error", {
        ignoreImmediateMutation: true,
        ignoreAccessorPattern: ["**.current", "**.displayName"],
      }],
      "functional/no-let": "error",

      // Functional programming rules - no statements
      "functional/no-loop-statements": "error",
      "functional/no-throw-statements": "error",
      "functional/no-return-void": "off",

      // Functional programming rules - no classes
      "functional/no-classes": "error",

      // Functional programming rules - prefer expressions
      "functional/prefer-tacit": "off",

      // TypeScript strict rules
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/no-empty-function": "off",

      // Require explicit return types on exported functions
      "@typescript-eslint/explicit-function-return-type": ["warn", {
        allowExpressions: true,
        allowTypedFunctionExpressions: true,
        allowHigherOrderFunctions: true,
        allowDirectConstAssertionInArrowFunctions: true,
      }],
    },
  },
  {
    // Test files need mutation for mocking (global.fetch = mockFetch, etc.)
    files: ["**/*.test.ts", "**/*.test.tsx", "**/test/**/*.ts", "**/test/**/*.tsx"],
    rules: {
      "functional/immutable-data": "off",
      "@typescript-eslint/no-unsafe-assignment": "off",
      "@typescript-eslint/no-unsafe-member-access": "off",
      "@typescript-eslint/no-unsafe-return": "off",
      "@typescript-eslint/no-unsafe-call": "off",
    },
  },
  {
    // Relax some TypeScript rules for Storybook stories
    files: ["**/*.stories.ts", "**/*.stories.tsx"],
    rules: {
      "@typescript-eslint/no-unsafe-assignment": "off",
      "@typescript-eslint/no-unsafe-member-access": "off",
    },
  },
  {
    // Ignore generated files
    ignores: [
      "src/routeTree.gen.ts",
      "dist/**",
      ".storybook/**",
    ],
  },
);
