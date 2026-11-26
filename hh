---
# apt install pipx -> pipx install uv -> venv avec un vieux Python pour toto.
#
# Compatible Ansible 2.10 et versions récentes, cibles Debian 13.
# Ansible < 2.18 ne sait pas utiliser le Python 3.13 de Debian 13 : les trois
# premières étapes passent donc par raw (aucun Python requis sur la cible),
# puis Ansible bascule sur le Python 3.8 installé par uv.
#
# Avec Ansible 2.10 :
#   - gather_facts: false dans le play qui appelle ce rôle ;
#   - ansible_python_interpreter: /usr/local/bin/python3.8 dans les group_vars
#     des hôtes Debian 13, pour les plays suivants.
#
# Pour rendre ces valeurs surchargeables depuis l'inventaire, déplace-les dans defaults/main.yml.

- name: pipx + uv + venv Python 3.8
  vars:
    uv_user: toto
    uv_python_version: "3.8"
    uv_venv_name: venv38        # créé dans le home de l'utilisateur
    uv_python_bin: "/usr/local/bin/python{{ uv_python_version }}"
  become: true
  block:
    - name: apt install pipx (+ acl, nécessaire pour become_user vers {{ uv_user }})
      ansible.builtin.raw: >-
        command -v pipx >/dev/null && command -v setfacl >/dev/null && echo DEJA_OK ||
        { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pipx acl; }
      register: r_pipx
      changed_when: "'DEJA_OK' not in r_pipx.stdout"

    - name: pipx install uv (global -> /usr/local/bin/uv)
      ansible.builtin.raw: >-
        test -x /usr/local/bin/uv && echo DEJA_OK || pipx install --global uv
      register: r_uv
      changed_when: "'DEJA_OK' not in r_uv.stdout"

    - name: Python {{ uv_python_version }} via uv (partagé dans /opt/uv/python, lien {{ uv_python_bin }})
      ansible.builtin.raw: >-
        test -x {{ uv_python_bin }} && echo DEJA_OK ||
        UV_PYTHON_INSTALL_DIR=/opt/uv/python UV_PYTHON_BIN_DIR=/usr/local/bin
        /usr/local/bin/uv python install {{ uv_python_version }}
      register: r_python
      changed_when: "'DEJA_OK' not in r_python.stdout"

    - name: Ansible < 2.18 utilise ce Python sur la cible
      ansible.builtin.set_fact:
        ansible_python_interpreter: "{{ uv_python_bin }}"
      when: ansible_version.full is version('2.18', '<')

    - name: Récupérer le home de {{ uv_user }}
      ansible.builtin.getent:
        database: passwd
        key: "{{ uv_user }}"

    - name: Créer le venv Python {{ uv_python_version }} de {{ uv_user }}
      ansible.builtin.command:
        cmd: >-
          /usr/local/bin/uv venv --seed
          --python {{ uv_python_bin }}
          {{ uv_home }}/{{ uv_venv_name }}
        creates: "{{ uv_home }}/{{ uv_venv_name }}/bin/python"
      vars:
        uv_home: "{{ ansible_facts['getent_passwd'][uv_user][4] }}"
      environment:
        HOME: "{{ uv_home }}"
      become_user: "{{ uv_user }}"