## 1.2.2 - 2025-09-08

### Added
- Comprehensive asset rebuild system with `mix phoenix_kit.assets.rebuild` task for automatic CSS integration
- System status checker with `mix phoenix_kit.status` task for installation diagnostics
- Asset management tools for PhoenixKit CSS integration updates and Tailwind CSS compatibility
- Common utility functions in `PhoenixKit.Install.Common` for version checking and installation management
- Helper functions for better code organization and separation of concerns
- Progress tracking and enhanced user feedback for migration operations
- Type specifications for Mix.Task modules and asset rebuild functions

### Changed
- CSS integration workflow simplified with better Tailwind CSS 4 support and @source directive optimization
- Migration function refactored to reduce cyclomatic complexity and improve maintainability
- Code organization improved with extraction of helper functions across multiple modules
- Enhanced error handling and user notifications for asset rebuild operations

### Fixed
- All Credo static analysis warnings (trailing whitespace, formatting issues, deep nesting)
- All Dialyzer type analysis warnings with proper function specifications
- CSS integration logic and @source directive paths for correct asset compilation
- Complex migration function broken down into smaller, more maintainable functions
- Conditional statements simplified (cond to if) for better code clarity

## 1.2.1 - 2025-09-07

### Added
- Project title customization system with dynamic branding across all admin interfaces
- Project title integration in authentication pages (login and registration)
- Time display enhancement showing both date and time in Users and Sessions tables
- Settings-aware date/time formatting functions for consistent user preferences

### Changed
- Date handling moved from PhoenixKit.Date to PhoenixKit.Utils.Date for better organization
- All admin pages now consistently display custom project title instead of hardcoded "PhoenixKit"
- Enhanced admin interface with unified project branding throughout navigation
- Login and registration pages now show custom project title in headings and browser tabs
- Changed config and magic link

## Fixed
- Fixed asset rebuilding integration in migration strategy

## 1.2.0 - 2025-09-03

### Added
- User settings system with customizable time zone, date format, and time format preferences
- Comprehensive session management system for admin interface with real-time tracking
- Live data updates system for admin panels with automatic refresh capabilities
- Automatic user logout functionality when role changes occur for enhanced security
- DateTime formatting functions with Timex library integration for better date/time handling
- Enhanced authentication session management for improved user experience

### Changed
- Authentication components updated with GitHub-inspired design and unified development notices
- Date handling refactored into separate PhoenixKit.Date module (aliased as PKDate) for better organization
- User dashboard "Registered" field now uses enhanced date formatting from settings
- Improved code quality and PubSub integration for better real-time communication

### Fixed
- Missing admin routes for settings and modules sections
- Dialyzer type errors resolved across the codebase
- Live Activity link in dashboard now correctly navigates to intended destination
- Settings tab information updated with accurate user preferences display

## 1.1.1 - 2025-09-02

### Added
- Profile settings functionality with first name and last name fields
- Profile changeset function for user profile updates
- Complete profile editing interface in user settings

### Fixed
- Router integration by removing unnecessary redirect pipe for login route
- Added admin shortcut route for improved navigation
- Enhanced admin dashboard accessibility

## 1.1.0 - 2025-09-01

### Changed
- **BREAKING**: Simplified role system by removing `is_active` column from role assignments
- Role removal now permanently deletes assignment records instead of soft deactivation
- All role-related functions updated to work with direct deletion approach
- Improved performance by eliminating `is_active` filtering in database queries
- Documenatation link fixed for hex

### Added
- V02 migration for upgrading existing installations to simplified role system
- Enhanced migration system with comprehensive upgrade path from V01 to V02
- Pre-migration reporting with warnings about inactive assignments that will be deleted
- Rollback support for V02 migration (though inactive assignments cannot be restored)

### Fixed
- Test suite updated to reflect schema new changes

### Migration Notes
- Existing V01 installations can upgrade using `mix phoenix_kit.update`
- V02 migration will permanently delete any inactive role assignments
- New installations will use V02 schema without `is_active` column

## 1.0.0 - 2025-08-29

Initial version with basic functionality, mostly around authorization and user registration with roles. Also admin page for admin users with User section.
