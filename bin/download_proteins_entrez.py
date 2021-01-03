#!/usr/bin/env python3
####################################################################################################
#
# Author: Sabrina Krakau
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
####################################################################################################
# for each strain: select largest assembly (for now)

import sys
import gzip
import csv
import xml.etree.ElementTree as ET
#import tqdm
import io
import argparse
import time

from Bio import Entrez, SeqIO
from pprint import pprint
from datetime import datetime
from collections import Counter, defaultdict
from urllib.error import HTTPError

import sys


# TODO
# clean code
# double check!


def parse_args(args=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('-t', "--taxid_input", required=True, nargs="+", metavar='FILE', type=argparse.FileType('r'), help="List of input files containing taxa IDs (and optionally abundances).")
    parser.add_argument('-m', "--microbiome_ids", required=True, nargs="+", help="List of corresponding microbiome IDs.")
    parser.add_argument('-e', "--email", required=True, help="Email address to use for NCBI access.")
    parser.add_argument('-k', "--key", required=True, help="NCBI key to allow faster access.")
    parser.add_argument('-p', "--proteins", required=True, metavar='FILE', help="Compressed TSV output file containing: protein_tmp_id, protein_sequence.")
    parser.add_argument('-ta', "--tax_ass_out", required=True, metavar='FILE', type=argparse.FileType('w'), help="Output file containing: tax_id, assembly_id.")
    parser.add_argument('-pa', "--prot_ass_out", required=True, metavar='FILE', type=argparse.FileType('w'), help="Output file containing: protein_id, assembly_id.")
    parser.add_argument('-pm', "--proteins_microbiomes", required=True, metavar='FILE', type=argparse.FileType('w'), help="Output file containing: protein_id, protein_weight, microbiome_id.")
    return parser.parse_args(args)


# get assembly length ("total_length") from entrez
def get_assembly_length(assemblyId):
    success = False
    for attempt in range(3):
        try:
            with Entrez.efetch(db="assembly", rettype="docsum", id=assemblyId) as entrez_handle:
                assembly_stats = Entrez.read(entrez_handle, validate=False)
            time.sleep(1)   # avoid getting blocked by ncbi
            success = True
            break
        except HTTPError as err:
            if 500 <= err.code <= 599:
                print("Received error from server %s" % err)
                print("Attempt %i of 3" % attempt)
                time.sleep(10)
            else:
                raise
    if not success:
        sys.exit("Entrez efetch download failed!")

    root = ET.fromstring("<root>" + str(assembly_stats['DocumentSummarySet']['DocumentSummary'][0]['Meta']) + "</root>")
    return root.find("./Stats/Stat[@category='total_length'][@sequence_tag='all']").text


# get protein weight based on (microbiome-wise) taxonomic abundances (if occuring in multiple taxa -> sum)
# NOTE multiple occurences of a protein within one assembly/genome are not counted!
def get_protein_weight(proteinId, dict_proteinId_assemblyIds, dict_taxId_assemblyId, dic_taxId_microbiomeId_abundance):
    dict_microbiomeId_proteinWeight = defaultdict(lambda : 0.0)
    for assembly in dict_proteinId_assemblyIds[proteinId]:
        for taxId, assembly2 in dict_taxId_assemblyId.items():
            if assembly == assembly2:
                for microbiomeId in dic_taxId_microbiomeId_abundance[taxId]:
                    dict_microbiomeId_proteinWeight[microbiomeId] += dic_taxId_microbiomeId_abundance[taxId][microbiomeId]
            break
    return dict_microbiomeId_proteinWeight


def main(args=None):
    args = parse_args(args)

    # setup entrez email
    Entrez.api_key = args.key
    Entrez.email = args.email

    # read taxonomic ids for download (together with abundances)
    dic_taxId_microbiomeId_abundance = defaultdict(lambda : {})
    for taxid_input, microbiomeId in zip(args.taxid_input, args.microbiome_ids):
        reader = csv.reader(taxid_input, delimiter='\t')
        header = next(reader)
        if header[0] != "taxid":
            print("ERROR: header is ", header)
            sys.exit("The format of the file provided with --taxid_input is invalid!")

        for row in reader:
            if len(header) == 2:
                dic_taxId_microbiomeId_abundance[row[0]][microbiomeId] = row[1]
            else:
                dic_taxId_microbiomeId_abundance[row[0]][microbiomeId] = 1

    print(dic_taxId_microbiomeId_abundance)
    print("Processing the following taxonmy IDs:")
    taxIds = dic_taxId_microbiomeId_abundance.keys()
    print(taxIds)

    ####################################################################################################
    # 1) for each taxId -> get all assembly IDs
    print("# taxa: ", len(taxIds))
    print("for each taxon retrieve assembly IDs ...")

    success = False
    for attempt in range(3):
        try:
            with Entrez.elink(dbfrom="taxonomy", db="assembly", LinkName="taxonomy_assembly", id=taxIds) as entrez_handle:
                assembly_results = Entrez.read(entrez_handle)
            time.sleep(1)   # avoid getting blocked by ncbi
            success = True
            break
        except HTTPError as err:
            if 500 <= err.code <= 599:
                print("Received error from server %s" % err)
                print("Attempt %i of 3" % attempt)
                time.sleep(10)
            else:
                raise
    if not success:
        sys.exit("Entrez elink download failed!")
    # print("assembly_results: ")
    # print(assembly_results)

    # 2) for each taxon -> select one assembly (largest for now)
    print("get assembly lengths and select largest assembly for each taxon ...")
    dict_taxId_assemblyId = {}
    for tax_record in assembly_results:
        taxId = tax_record["IdList"][0]
        if len(tax_record["LinkSetDb"]) > 0:
            # get all assembly ids
            ids = [ assembly_record["Id"] for assembly_record in tax_record["LinkSetDb"][0]["Link"] ]
            # get corresponding lengths
            lengths = [get_assembly_length(id) for id in ids]
            # get id for largest assembly
            selected_assemblyId = ids[lengths.index(max(lengths))]
            dict_taxId_assemblyId[taxId] = selected_assemblyId
    # print("dict")
    # print(dict_taxId_assemblyId)

    # write taxId - assemblyId out
    print("taxon", "assembly", sep='\t', file=args.tax_ass_out, flush=True)
    for taxon in dict_taxId_assemblyId.keys():
            print(taxon, dict_taxId_assemblyId[taxon], sep='\t', file=args.tax_ass_out, flush=True)

    # 3) (selected) assembly -> nucleotide sequences
    # (maybe split here)
    assemblyIds = dict_taxId_assemblyId.values()
    print("# selected assemblies: ", len(assemblyIds))
    print("for each assembly get nucloetide sequence IDs...")

    success = False
    for attempt in range(3):
        try:
            with Entrez.elink(dbfrom="assembly", db="nuccore", LinkName="assembly_nuccore_refseq", id=assemblyIds) as entrez_handle:
                nucleotide_results = Entrez.read(entrez_handle)
            time.sleep(1)   # avoid getting blocked by ncbi
            success = True
            break
        except HTTPError as err:
            if 500 <= err.code <= 599:
                print("Received error from server %s" % err)
                print("Attempt %i of 3" % attempt)
                time.sleep(10)
            else:
                raise
    if not success:
            sys.exit("Entrez elink download failed!")
    # print("nucleotide_results: ")
    # print(nucleotide_results)

    ### for each assembly get list of sequence ids
    # seq_ids = [ record["Id"] for assembly_record in nucleotide_results for record in assembly_record["LinkSetDb"][0]["Link"] ]

    dict_seqId_assemblyIds = defaultdict(lambda : [])
    for assembly_record in nucleotide_results:
        assemblyId = assembly_record["IdList"][0]
        for record in assembly_record["LinkSetDb"][0]["Link"]:
            dict_seqId_assemblyIds[record["Id"]].append(assemblyId)

    print("# nucleotide sequences (unique): ", len(dict_seqId_assemblyIds.keys()))
    # -> # contigs

    # 4) nucelotide sequences -> proteins
    print("for each nucleotide sequence get proteins ...")

    success = False
    for attempt in range(3):
        try:
            with Entrez.elink(dbfrom="nuccore", db="protein", LinkName="nuccore_protein", id=list(dict_seqId_assemblyIds.keys())) as entrez_handle:
                protein_results = Entrez.read(entrez_handle)
            time.sleep(1)   # avoid getting blocked by ncbi
            success = True
            break
        except HTTPError as err:
            if 500 <= err.code <= 599:
                print("Received error from server %s" % err)
                print("Attempt %i of 3" % attempt)
                time.sleep(10)
            else:
                raise
    if not success:
            sys.exit("Entrez elink download failed!")
    # print("protein_results: ")
    # print(protein_results)

    ### for each nucleotide sequence get list of protein ids
    # protein_ids = [ record["Id"] for nuc_record in protein_results for record in nuc_record["LinkSetDb"][0]["Link"] ]

    dict_proteinId_assemblyIds = {}
    for nucleotide_record in protein_results:
        seqId = nucleotide_record["IdList"][0]
        assemblyIds = dict_seqId_assemblyIds[seqId]
        # print("assemblyIds")
        # print(assemblyIds)
        if len(nucleotide_record["LinkSetDb"]) > 0:
            for protein_record in nucleotide_record["LinkSetDb"][0]["Link"]:
                if protein_record["Id"] not in dict_proteinId_assemblyIds:
                    dict_proteinId_assemblyIds[protein_record["Id"]] = assemblyIds
                else:
                    for i in assemblyIds:
                        if i not in dict_proteinId_assemblyIds[protein_record["Id"]]:
                            dict_proteinId_assemblyIds[protein_record["Id"]].append(i)

    # NOTE:
    # some proteins, such as 487413233, occur within multiple sequences of the assembly!
    # -> assembly only listed once!

    proteinIds = list(dict_proteinId_assemblyIds.keys())

    print("# proteins (unique): ", len(proteinIds))
    # -> # proteins with refseq source (<= # IPG proteins)

    # protein_id, assembly_ids
    print("protein_tmp_id", "assemblies", sep='\t', file=args.prot_ass_out)
    for proteinId in proteinIds:
        print(proteinId, ','.join(dict_proteinId_assemblyIds[proteinId]), sep='\t', file=args.prot_ass_out, flush=True)

    # 5) download protein FASTAs, convert to TSV
    # print("    download proteins ...")
    # (or if mem problem: assembly-wise)
    # TODO check if max. number of item that can be returned by efetch (retmax)!? compare numbers!

    # first retrieve mapping for protein UIDs and accession versions
    success = False
    for attempt in range(3):
        try:
            with Entrez.esummary(db="protein", id=",".join(proteinIds)) as entrez_handle:   # esummary doesn't work on python lists somehow
                protein_summaries = Entrez.read(entrez_handle)
            time.sleep(1)   # avoid getting blocked by ncbi
            success = True
            break
        except HTTPError as err:
            if 500 <= err.code <= 599:
                print("Received error from server %s" % err)
                print("Attempt %i of 3" % attempt)
                time.sleep(10)
            else:
                raise
    if not success:
            sys.exit("Entrez esummary download failed!")

    dict_protein_uid_acc = {}
    for protein_summary in protein_summaries:
        dict_protein_uid_acc[protein_summary["Id"]] = protein_summary["AccessionVersion"]

    # download actual fasta records and write out
    success = False
    for attempt in range(3):
        try:
            with Entrez.efetch(db="protein", rettype="fasta", retmode="text", id=proteinIds) as entrez_handle:
                with gzip.open(args.proteins, 'wt') as out_handle:
                    print("protein_tmp_id", "protein_sequence", sep='\t', file=out_handle)
                    for record in SeqIO.parse(entrez_handle, "fasta"):
                        print(record.id, record.seq, sep='\t', file=out_handle, flush=True)
            time.sleep(1)   # avoid getting blocked by ncbi
            success = True
            break
        except HTTPError as err:
            if 500 <= err.code <= 599:
                print("Received error from server %s" % err)
                print("Attempt %i of 3" % attempt)
                time.sleep(10)
            else:
                raise
    if not success:
            sys.exit("Entrez efetch download failed!")

    # 6) write out protein weights obtained from taxonomic abundances
    print("protein_tmp_id", "protein_weight", "microbiome_id", sep='\t', file=args.proteins_microbiomes, flush=True)
    for proteinId in proteinIds:
        # get protein weights for respective microbiome IDs
        dict_microbiomeId_proteinWeight = get_protein_weight(proteinId, dict_proteinId_assemblyIds, dict_taxId_assemblyId, dic_taxId_microbiomeId_abundance)
        for microbiomeId in dict_microbiomeId_proteinWeight:
            weight = dict_microbiomeId_proteinWeight[microbiomeId]
            accVersion = dict_protein_uid_acc[proteinId]
            print(accVersion, weight, microbiomeId, sep='\t', file=args.proteins_microbiomes, flush=True)

    print("Done!")


if __name__ == "__main__":
    sys.exit(main())
