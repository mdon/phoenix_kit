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
