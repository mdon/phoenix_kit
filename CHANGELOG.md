## 1.1.0 - 2025-09-01

### Changed
- **BREAKING**: Simplified role system by removing `is_active` column from role assignments
- Role removal now permanently deletes assignment records instead of soft deactivation
- All role-related functions updated to work with direct deletion approach
- Improved performance by eliminating `is_active` filtering in database queries
- Documenation link fixed for hex

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
