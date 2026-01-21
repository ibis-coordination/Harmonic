import type { Preview } from '@storybook/react-vite'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import {
  RouterProvider,
  createRouter,
  createRootRoute,
  createMemoryHistory,
  Outlet,
} from '@tanstack/react-router'
import React from 'react'
import '../src/index.css'

// Create a fresh QueryClient for each story
const createQueryClient = () =>
  new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
        staleTime: Infinity,
      },
    },
  })

// Wrapper component that provides all contexts
function StoryWrapper({ children }: { children: React.ReactNode }) {
  const queryClient = React.useMemo(() => createQueryClient(), [])

  // Create a router that renders children in its root route
  const router = React.useMemo(() => {
    const rootRoute = createRootRoute({
      component: () => (
        <>
          <Outlet />
          {children}
        </>
      ),
    })

    return createRouter({
      routeTree: rootRoute,
      history: createMemoryHistory({ initialEntries: ['/'] }),
    })
  }, [children])

  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  )
}

const preview: Preview = {
  parameters: {
    controls: {
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },
  },
  decorators: [
    (Story) => (
      <StoryWrapper>
        <Story />
      </StoryWrapper>
    ),
  ],
}

export default preview
