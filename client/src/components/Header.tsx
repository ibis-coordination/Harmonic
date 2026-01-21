import { Link } from "@tanstack/react-router"
import { useAppStore } from "@/stores/app"

export function Header() {
  const { currentUser, currentSuperagent } = useAppStore()

  return (
    <header className="border-b border-gray-200 bg-white">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="flex h-14 items-center justify-between">
          <div className="flex items-center gap-4">
            <Link to="/" className="text-xl font-semibold text-gray-900">
              Harmonic
            </Link>
            {currentSuperagent.handle && (
              <>
                <span className="text-gray-400">/</span>
                <Link
                  to="/studios/$handle"
                  params={{ handle: currentSuperagent.handle }}
                  className="text-gray-600 hover:text-gray-900"
                >
                  {currentSuperagent.name ?? currentSuperagent.handle}
                </Link>
              </>
            )}
          </div>

          <nav className="flex items-center gap-6">
            {currentUser ? (
              <>
                <span className="text-sm text-gray-600">
                  {currentUser.display_name}
                </span>
                <a
                  href={`/u/${currentUser.handle}/settings`}
                  className="text-sm text-gray-600 hover:text-gray-900"
                >
                  Settings
                </a>
                <a
                  href="/logout"
                  data-turbo-method="delete"
                  className="text-sm text-gray-600 hover:text-gray-900"
                >
                  Sign out
                </a>
              </>
            ) : (
              <a
                href="/login"
                className="text-sm text-gray-600 hover:text-gray-900"
              >
                Sign in
              </a>
            )}
          </nav>
        </div>
      </div>
    </header>
  )
}
