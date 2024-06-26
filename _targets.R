# Copyright 2021 Province of British Columbia
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and limitations under the License.

library(targets)
library(tarchetypes)
source("packages.R")
source("R/functions.R")

conflict_prefer("filter", "dplyr")
plan(callr)


# load datasets ------------------------------------------------------------------------------------

load_datasets <- list(
  tar_target(pa_data, get_cpcad_bc_data()),
  tar_target(ecoregions, load_ecoregions()),
  tar_target(bec, load_bec())
)

# clean data --------------------------------------------------------------
clean_data <- list(
  tar_target(clean_pa, remove_overlaps(pa_data)),
  tar_target(clipped_bec, clip_to_bc_boundary(bec, simplify = TRUE)),
  tar_target(clipped_eco, clip_to_bc_boundary(ecoregions, simplify = TRUE))
)

# intersect data ----------------------------------------------------------
intersect_data <- list(
  tar_target(eco_bec, intersect_pa(ecoregions, bec)),
  tar_target(eco_bec_clipped, clip_to_bc_boundary(eco_bec, simplify = FALSE)),
  tar_target(eco_bec_output, eco_rep_full(eco_bec_clipped)),
  tar_target(pa_eco_bec, intersect_pa(clean_pa, eco_bec_output))
)

# simplify spatial data  --------------------------------------------------
simplify_data <- list(
  tar_target(map_eco_background, simplify_background_map(clipped_eco, agg = c("ecrgn_c", "ecrgn_n"))),
  tar_target(map_bec_background, simplify_background_map(clipped_bec, agg = c("zone", "subzone", "variant"))),
  # Redo intersection rather than simplify eco_bec otherwise slivers are simplified into oblivion and makes
  # lots of empty geometries and invalid topologies
  tar_target(map_eco_bec_background, intersect_pa(map_eco_background, map_bec_background) %>%
    group_by(ecrgn_n, ecrgn_c, zone, subzone, variant) %>%
    summarise()),
  # Just use rmapshaper::ms_simplify due to bug in sf: https://github.com/r-spatial/sf/issues/1767
  tar_target(map_pa_background, rmapshaper::ms_simplify(clean_pa, keep = 0.05, keep_shapes = TRUE, sys = TRUE) %>%
               st_make_valid()),
  #tar_target(map_pa_background, simplify_background_map(clean_pa)),
  tar_target(parks_removed, remove_pa(map_eco_bec_background, map_pa_background))
)

# analyze and prepare for visualization -----------------------------------
summarise_data <- list(
  tar_target(eco_bec_summary, #calculate the percent composition of each variant/ecoregion combo
             eco_bec_clipped %>%
               mutate(area = st_area(.),
                      area = as.numeric(set_units(area, ha))) %>%
               st_drop_geometry() %>%
               group_by(ecrgn_n, ecrgn_c, zone, subzone, variant, bgc_label) %>%
               summarise(bec_eco_area = sum(area), .groups = "drop") %>%
               mutate(percent_comp_prov = bec_eco_area / sum(bec_eco_area) * 100) %>%
               group_by(ecrgn_c) %>%
               mutate(percent_comp_ecoregion = bec_eco_area / sum(bec_eco_area) * 100)
             ),
  tar_target(pa_eco_bec_summary,
             eco_bec_summary %>%
               left_join(
                 pa_eco_bec %>%
                   mutate(conserved_area = st_area(.),
                          conserved_area = as.numeric(set_units(conserved_area, ha)))%>%
                   st_drop_geometry() %>%
                   group_by(ecrgn_n, ecrgn_c, zone, subzone, variant, pa_type) %>%
                   summarise(conserved_area = sum(conserved_area), .groups = "drop"),
                 by = c("ecrgn_n", "ecrgn_c", "zone", "subzone", "variant")
               ) %>%
               complete(nesting(ecrgn_c, ecrgn_n, zone, subzone, variant),
                        pa_type = c("ppa", "oecm"), fill = list(conserved_area = 0)) %>%
               group_by(ecrgn_c, zone, subzone, variant) %>%
               fill(bec_eco_area, percent_comp_prov, percent_comp_ecoregion, .direction = "downup") %>%
               ungroup() %>%
               dplyr::filter(!is.na(pa_type)) %>%
               mutate(percent_conserved = conserved_area / bec_eco_area * 100)
  ),
  tar_target(pa_eco_bec_summary_wide,
             pa_eco_bec_summary %>%
               select(-percent_conserved) %>%
               pivot_wider(names_from = pa_type, values_from = conserved_area, values_fill = 0) %>%
               mutate(total_conserved = ppa + oecm,
                      percent_conserved_total = total_conserved / bec_eco_area * 100,
                      percent_conserved_ppa = ppa / bec_eco_area * 100,
                      percent_conserved_oecm = oecm / bec_eco_area * 100)
             ),
  tar_target(pa_bec_summary_wide,
             pa_eco_bec_summary_wide %>%
               select(-percent_comp_ecoregion, bec_area = bec_eco_area) %>%
               group_by(zone, subzone, variant, bgc_label) %>%
               summarise(across(where(is.numeric), .fns = sum, na.rm = TRUE), .groups = "drop") %>%
               mutate(percent_conserved_total = total_conserved / bec_area * 100,
                      percent_conserved_ppa = ppa / bec_area * 100,
                      percent_conserved_oecm = oecm / bec_area * 100)),
  tar_target(pa_eco_summary_wide,
             pa_eco_bec_summary_wide %>%
               select(-percent_comp_ecoregion, eco_area = bec_eco_area) %>%
               group_by(ecrgn_c, ecrgn_n) %>%
               summarise(across(where(is.numeric), .fns = sum, na.rm = TRUE), .groups = "drop") %>%
               mutate(percent_conserved_total = total_conserved / eco_area * 100,
                      percent_conserved_ppa = ppa / eco_area * 100,
                      percent_conserved_oecm = oecm / eco_area * 100))
)



# Save csv outputs ----------------------------------

save_csvs <- list(
  tar_target(eco_bec_summary_csv, write_csv_data(eco_bec_summary), format = "file"),
  tar_target(pa_eco_bec_summary_csv, write_csv_data(pa_eco_bec_summary_wide), format = "file"),
  tar_target(pa_eco_summary_csv, write_csv_data(pa_eco_summary_wide), format = "file"),
  tar_target(pa_bec_summary_csv, write_csv_data(pa_bec_summary_wide), format = "file")
)

save_output <- list(
  tar_target(ecosystem_representation, eco_rep_layer(eco_bec_output, pa_bec_summary_wide, pa_eco_bec_summary_wide))#,
  #tar_target(underrepresented_layer, eco_rep_layer_mod(ecosystem_representation, 5, 17))
)


# supplemental bec zone plots ---------------------------------------------
# **** currently not being used - plots are created in Rmd ****
plot_data <- list(
  #tar_target(bec_plot_type, plot_by_bec_zone(pa_bec_sum)),
  #tar_target(bec_plot_total, plot_bec_zone_totals(pa_bec_sum)),
  tar_target(bec_map_figure, bec_zone_map(map_bec)),
  tar_target(bc_button, create_bc_button())
)


# targets pipeline --------------------------------------------------------
list(
  load_datasets,
  clean_data,
  intersect_data,
  simplify_data,
  summarise_data,
  #plot_data,
  save_csvs,
  save_output,
  tar_render(report_html, "eco_rep_report.Rmd", output_format = "html_document"),
  tar_render(report_pdf, "eco_rep_report.Rmd", output_format = "pdf_document")
)
#add list(,
#tar_targets() for each intermediate step of workflow)
