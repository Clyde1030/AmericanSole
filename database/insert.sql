insert into core.company (name) values
('American Sole LLC'),
('US Boot'),
('Brunt Workwear'),
('Chippewa Boots'),
('Fire-Dex'),
('Wolverine Worldwide'),
('Light House');

insert into core.company_role_type (name)
('Customer'),
('Vendor'),
('Retailer'),
('Wholesaler');

insert into core.address (company_id, line1, city, state, postal_code, country, is_primary)
(1, '123 Main St', 'Anytown', 'NY', '12345', 'USA', true),
(2, '456 Elm St', 'Othertown', 'CA', '67890', 'USA', true);
