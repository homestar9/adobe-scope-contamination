/**
 * AlphaChild — belongs to AlphaParent via alpha_parent_id.
 *
 * NOTE: the foreign-key column is named `alpha_parent_id`. This name does NOT
 * exist on bravo_child, so if a contaminated UPDATE targets bravo_child while
 * still SETting alpha_parent_id, SQL Server throws "Invalid column name".
 */
component
	extends   ="quick.models.BaseEntity"
	accessors ="true"
	table     ="alpha_child"
{

	property name="id";
	property name="name";
	property name="alpha_parent_id";

}
