/**
 * BravoChild — belongs to BravoParent via bravo_parent_id.
 *
 * The foreign-key column `bravo_parent_id` does NOT exist on alpha_child,
 * mirroring AlphaChild. See AlphaChild.cfc for the contamination rationale.
 */
component
	extends   ="quick.models.BaseEntity"
	accessors ="true"
	table     ="bravo_child"
{

	property name="id";
	property name="name";
	property name="bravo_parent_id";

}
